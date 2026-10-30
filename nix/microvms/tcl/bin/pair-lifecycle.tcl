# pair-lifecycle.tcl --
#
#	The pair lifecycle test (homa-pair-lifecycle): two guests, node0 the
#	server and node1 the client, on a private eth1 link, driven from the
#	host over each one's hvc0 with every phase timed. Neither guest runs a
#	test of its own.
#
#	    1-3    start, serial, virtio     each node
#	    4      insmod                    each node
#	    5      link                      node1 pings node0 over eth1
#	    6      servers                   demo_server1 and cp_node servers on node0
#	    7      traffic baseline          from node1: echo (six RPCs, 100 B .. 1 MB),
#	                                     cp_node Homa, cp_node TCP; counter deltas
#	    8.i    netem <name>              tc netem on eth1 of both nodes, then the
#	           traffic <name>            same traffic. Each node's measured drop
#	                                     rate must match the configured loss, and
#	                                     with loss, Homa must have sent RESENDs
#	    9      netem clear, traffic recovered
#	    10     qdisc homa                Homa's qdisc on eth1 of both nodes, then
#	                                     traffic through it (TCP must pass it too)
#	    11     qdisc paced               net.homa.link_mbps lowered so the pacer
#	                                     must defer packets; traffic
#	    12     qdisc off                 link_mbps restored, default qdisc back
#	    13     stop servers
#	    14     rmmod                     each node
#	    15-18  dmesg, shutdown, exit, serial-log   each node
#
#	    pair-lifecycle.tcl config.json
#
#	config.json is written by host/pair-lifecycle.nix. Logs go to
#	$HOMA_VM_LOGDIR (default: a new temporary directory): node0/ and node1/
#	(each its QEMU's working directory, with serial.log), and
#	traffic/<name>/ per traffic run. Exits 1 if any phase fails.

package require homa::lc
package require json
namespace import ::homa::lc::parse ::homa::lc::report

# Pair --
#
#	One pair lifecycle run: the two guests, the phase table, and the
#	phases that span both guests.
#
#	    set pair [Pair new $configFile]
#	    exit [$pair run]

oo::class create Pair {
    # config	the parsed config.json.
    # table	the run's homa::lc::Table.
    # nodes	node name -> homa::lc::Node, for node0 and node1.
    # timeout	seconds for an ordinary command.
    variable config table nodes timeout

    # constructor --
    #
    #	Reads configFile, moves to the log directory and creates the nodes
    #	(without starting them).
    #
    # Arguments:
    #	configFile	the path of config.json.
    #
    # Results:
    #	None.
    #
    # Side effects:
    #	Changes the current directory to the log directory and prints where
    #	the logs are.

    constructor {configFile} {
        set config [json::json2dict [homa::lc::readFile $configFile]]
        set timeout [dict get $config timeouts command]
        set logdir [homa::lc::logdir]
        cd $logdir
        puts "pair lifecycle[dict get $config label]: logs in $logdir"
        set table [homa::lc::Table new]
        set nodes [dict create]
        foreach key {node0 node1} {
            dict set nodes $key [homa::lc::Node new $table $key [dict get $config $key] \
                [dict get $config timeouts] " $key"]
        }
    }

    # destructor --
    #
    #	Stops both guests.

    destructor {
        dict for {key node} $nodes {
            $node destroy
        }
        $table destroy
    }

    # run --
    #
    #	Runs every phase.
    #
    # Results:
    #	The exit code: 0 if every phase passed, otherwise 1.
    #
    # Side effects:
    #	Boots, drives and stops both guests, records each phase in the
    #	table, writes the logs and summary.md, and prints each phase, the
    #	HOMA_PAIR_* lines and the verdict.

    method run {} {
        foreach step {start serial virtio} id {1 2 3} {
            dict for {key guest} $nodes {
                $guest $step $id
            }
        }

        my EachNode node 4 insmod {
            set result [$node run insmod.log $timeout {insmod "$HOMA_KO" 2>&1}]
            list [dict get $result rc] [parse firstLine [dict get $result out]]
        }

        set peer [dict get $config peer]
        set client [my Node node1]
        set server [my Node node0]
        $client phase 5 link {
            set result [$client run ping.log $timeout "for i in \$(seq 20); do ping -c 1\
                -W 1 $peer > /dev/null && break; done; ping -q -c 3 -W 2 $peer"]
            set summary [lsearch -all -inline -regexp [split [dict get $result out] \n] \
                {packet loss|rtt}]
            list [dict get $result rc] [join $summary " "]
        }

        # Each server in a subshell, so the console's shell has no jobs to
        # report.
        set homaPort [dict get $config cpNode homaPort]
        $server phase 6 servers {
            set daemons [list \
                "demo_server1 > /tmp/demo_server1.log" \
                "cp_node server --protocol homa --first-port $homaPort\
                    > /tmp/cp_node_homa.log" \
                "cp_node server --protocol tcp > /tmp/cp_node_tcp.log"]
            set start [join [lmap cmd $daemons {string cat "($cmd 2>&1 < /dev/null &)"}] "; "]
            set result [$server run servers.log $timeout "$start; sleep 1; echo\
                demo_server1=\$(pgrep -cx demo_server1) cp_node=\$(pgrep -cx cp_node)"]
            set running [parse lastLine [dict get $result out]]
            list [expr {$running eq "demo_server1=1 cp_node=2" ? [dict get $result rc] : 1}] \
                $running
        }

        my Traffic 7 baseline
        set i 0
        foreach impairment [dict get $config netem phases] {
            lassign [lmap key {name args loss} {dict get $impairment $key}] name netemArgs loss
            incr i
            my Netem 8.$i $name $netemArgs
            my Traffic 8.$i $name $loss [expr {$loss == 0 ? "" : "packets_sent_RESEND"}]
        }
        my OnBoth 9 "netem clear" netem-clear.log \
            "tc qdisc del dev eth1 root && ! tc qdisc show dev eth1 | grep -q netem" \
            "default qdisc on eth1"
        my Traffic 9 recovered

        # The pacer works from the link speed. virtio-net reports none
        # (SPEED_UNKNOWN: round-4 candidate 5), so phase 11 sets
        # net.homa.link_mbps, which the qdisc then uses, low enough that the
        # pacer has to defer packets.
        my OnBoth 10 "qdisc homa" qdisc-on.log [join {
            {sysctl -n net.homa.link_mbps > /tmp/link_mbps}
            {homa-qdisc on > /tmp/qdisc.out && head -n 1 /tmp/qdisc.out\
                && grep '^qdisc homa' /tmp/qdisc.out}
        } "; "]
        my Traffic 10 homa-qdisc "" qdisc_tcp_packets
        my OnBoth 11 "qdisc paced" qdisc-paced.log \
            "sysctl -w net.homa.link_mbps=[dict get $config pacedMbps]"
        my Traffic 11 homa-qdisc-paced "" pacer_homa_packets
        my OnBoth 12 "qdisc off" qdisc-off.log [join {
            {sysctl -w net.homa.link_mbps=$(cat /tmp/link_mbps)}
            {homa-qdisc off}
            {! tc qdisc show dev eth1 | grep -q '^qdisc homa'}
        } " && "]

        $server phase 13 "stop servers" {
            set result [$server run servers.log $timeout [join {
                {pkill -x demo_server1} {pkill -x cp_node} {sleep 1}
                {! pgrep -x 'demo_server1|cp_node'}
            } "; "] a]
            list [dict get $result rc] ""
        }

        my EachNode node 14 rmmod {
            set result [$node run rmmod.log $timeout {rmmod homa 2>&1}]
            list [dict get $result rc] [parse firstLine [dict get $result out]]
        }
        foreach step {dmesg shutdown waitExit serialLog} id {15 16 17 18} {
            dict for {key guest} $nodes {
                $guest $step $id
            }
        }
        return [$table verdict]
    }

    # ---- Phases on both nodes --------------------------------------------------

    # Traffic --
    #
    #	One traffic run from node1 to node0 (see Measure), judged and
    #	described by report trafficDetail.
    #
    # Arguments:
    #	id, name	the phase; it is named "traffic <name>".
    #	loss		netem's configured loss in percent, or "" without
    #			netem. With netem, each node's measured drop rate is
    #			checked against it.
    #	must		a counter that must have moved (summed over both
    #			nodes), or "": packets_sent_RESEND under loss, the
    #			qdisc and pacer counters with Homa's qdisc.
    #
    # Results:
    #	The phase's rc, or skip.
    #
    # Side effects:
    #	Records the phase; runs the traffic on both guests; writes
    #	traffic/<name>/ (logs and deltas); prints the counter deltas, and
    #	for the baseline, the HOMA_PAIR_* lines.

    method Traffic {id name {loss {}} {must {}}} {
        my BothPhase $id "traffic $name" {
            set dir [file join [pwd] traffic $name]
            file mkdir $dir
            set measured [my Measure $dir $loss]
            set deltaLines [lmap {key counters} [dict get $measured deltas] {
                string cat "$key: " [report deltaLine $counters]
            }]
            homa::lc::writeFile [file join $dir deltas] [join $deltaLines \n]
            set outcome [report trafficDetail $measured [dict get $config echoRpcs] $must]

            if {$name eq "baseline"} {
                # The lines homa-vm-matrix puts in its table.
                puts "HOMA_PAIR_ECHO responses=[dict get $measured echoes]\
                    (want [dict get $config echoRpcs])"
                puts "HOMA_PAIR_CPNODE_homa [dict get $measured homa]"
                puts "HOMA_PAIR_CPNODE_tcp [dict get $measured tcp]"
            }
            foreach line $deltaLines {
                puts "    $line"
            }
            set rc [expr {[llength [dict get $outcome failed]] ? 1 : [dict get $measured rc]}]
            list $rc [dict get $outcome detail]
        }
    }

    # Netem --
    #
    #	Replaces eth1's root qdisc with netem on both nodes, so its counters
    #	start from zero, and checks that the limit took. The detail is
    #	node1's netem settings.
    #
    # Arguments:
    #	id, name	the phase; it is named "netem <name>".
    #	netemArgs	the arguments to tc's netem qdisc.
    #
    # Results:
    #	The phase's rc, or skip.
    #
    # Side effects:
    #	Replaces eth1's root qdisc on both guests, writes netem-<name>.log
    #	in each node's directory, and records the phase.

    method Netem {id name netemArgs} {
        set limit [dict get $config netem limit]
        my BothPhase $id "netem $name" {
            set rc 0
            set outs [dict create]
            dict for {key node} $nodes {
                set result [$node run netem-$name.log $timeout [join [list \
                    {tc qdisc del dev eth1 root 2> /dev/null} \
                    "tc qdisc add dev eth1 root netem $netemArgs && tc qdisc show dev eth1"] "; "]]
                dict set outs $key [dict get $result out]
                if {[dict get $result rc] || ![parse netemLimitOk [dict get $result out] $limit]} {
                    set rc 1
                }
            }
            list $rc [parse netemDetail [dict get $outs node1]]
        }
    }

    # OnBoth --
    #
    #	Runs one command on both nodes as a single phase. The detail is
    #	given, or else node1's output on one line.
    #
    # Arguments:
    #	id, name	the phase.
    #	log		the log file's name in each node's directory.
    #	cmd		the command.
    #	detail		the phase's detail, or "" for node1's output.
    #
    # Results:
    #	The phase's rc, or skip.
    #
    # Side effects:
    #	Runs cmd on both guests, writes log on each, and records the phase.

    method OnBoth {id name log cmd {detail {}}} {
        my BothPhase $id $name {
            set rc 0
            set outs [dict create]
            dict for {key node} $nodes {
                set result [$node run $log $timeout $cmd]
                dict set outs $key [dict get $result out]
                set rc [report combine $rc [dict get $result rc]]
            }
            if {$detail eq ""} {
                set detail [regsub -all { +} [string map {\n " "} [dict get $outs node1]] " "]
            }
            list $rc $detail
        }
    }

    # ---- Internals ---------------------------------------------------------------

    # Measure --
    #
    #	Runs the traffic from node1 to node0 (echo, then cp_node over Homa
    #	and over TCP) between two counter snapshots of each node, and with
    #	netem, reads each node's drops. Logs go to dir.
    #
    # Arguments:
    #	dir	the run's log directory.
    #	loss	netem's configured loss in percent, or "" without netem.
    #
    # Results:
    #	The measured dictionary report trafficDetail takes, plus rc: the
    #	snapshots' combined exit status.
    #
    # Side effects:
    #	Runs the traffic and counter reads on the guests and writes their
    #	logs to dir.

    method Measure {dir loss} {
        set client [my Node node1]
        lassign [my Snapshot $dir stats0] status0 before

        set echoTimeout [dict get $config timeouts echo]
        set echo "timeout [expr {$echoTimeout - 10}] demo_client1 [dict get $config peer] 4000\
            > /tmp/echo.out 2>&1 < /dev/null; grep -c '^Received response' /tmp/echo.out"
        set echoCount [parse lastLine [dict get \
            [$client run [file join $dir echo.log] $echoTimeout $echo] out]]
        foreach proto {homa tcp} {
            set stats($proto) [parse lastLine [dict get \
                [$client run [file join $dir $proto.log] $timeout [my CpNode $proto]] out]]
        }

        lassign [my Snapshot $dir stats1] status1 after
        set moved [dict map {key counters} $after {
            parse delta [dict get $before $key] $counters
        }]
        set drops [dict create]
        if {$loss ne ""} {
            dict for {key node} $nodes {
                dict set drops $key [parse netemCheck $key [dict get [$node run \
                    [file join $dir $key-tc] $timeout "tc -s qdisc show dev eth1"] out] $loss]
            }
        }
        return [dict create rc [report combine $status0 $status1] echoes $echoCount \
            homa $stats(homa) tcp $stats(tcp) deltas $moved checks $drops]
    }

    # Snapshot --
    #
    #	Reads Homa's counters on each node, logging them to
    #	dir/<node>-<name>.
    #
    # Arguments:
    #	dir	the log directory.
    #	name	the snapshot's name, e.g. stats0.
    #
    # Results:
    #	A list: the combined exit status, and node name -> counters.
    #
    # Side effects:
    #	Runs homa-node-stats on both guests and writes dir/<node>-<name>.

    method Snapshot {dir name} {
        set status 0
        set counters [dict create]
        dict for {key node} $nodes {
            set result [$node run [file join $dir $key-$name] $timeout homa-node-stats]
            set status [report combine $status [dict get $result rc]]
            dict set counters $key [parse snap [dict get $result out] [dict get $config metrics]]
        }
        return [list $status $counters]
    }

    # CpNode --
    #
    #	Builds the command for one cp_node client run over proto, which
    #	prints cp_node's last stats line. Output goes to a file, grepped
    #	afterwards: under the console shell's job control, timeout's SIGTERM
    #	also reaches the rest of a pipeline, losing its output.
    #
    # Arguments:
    #	proto	homa or tcp.
    #
    # Results:
    #	The command.
    #
    # Side effects:
    #	None.

    method CpNode {proto} {
        lassign [lmap key {workload gbps seconds homaPort} {dict get $config cpNode $key}] \
            workload gbps seconds homaPort
        set options [list --protocol $proto --workload $workload --gbps $gbps \
            --first-server 0 --server-nodes 1 --id 1]
        if {$proto eq "homa"} {
            lappend options --first-port $homaPort
        }
        set out /tmp/cp_node_$proto.out
        return "timeout $seconds cp_node client [join $options] > $out 2>&1 < /dev/null;\
            grep ' clients: ' $out | tail -n 1"
    }

    # Node --
    #
    #	Looks up one of the nodes.
    #
    # Arguments:
    #	name	node0 or node1.
    #
    # Results:
    #	The homa::lc::Node called name.
    #
    # Side effects:
    #	None.

    method Node {name} {
        return [dict get $nodes $name]
    }

    # BothPhase --
    #
    #	A phase that needs both nodes' shells: runs script as Table phase
    #	does, in the caller's scope, or SKIPs it naming which shell is gone.
    #
    # Arguments:
    #	id, name	the phase.
    #	script		the phase script; it returns {rc detail}.
    #
    # Results:
    #	The phase's rc, or skip.
    #
    # Side effects:
    #	Runs script and records the phase (or the SKIP) in the table.

    method BothPhase {id name script} {
        set up [lmap key {node0 node1} {[my Node $key] shell}]
        if {$up ne "1 1"} {
            $table skip $id $name [format "no shell on hvc0 (node0 %d, node1 %d)" {*}$up]
            return skip
        }
        tailcall $table phase $id $name $script
    }

    # EachNode --
    #
    #	Runs a phase on each node, as "<name> <node>", like foreach: script
    #	runs in the caller's scope with varName set to the homa::lc::Node,
    #	and a node without a shell SKIPs it (see homa::lc::Node phase).
    #
    # Arguments:
    #	varName		the caller's variable set to each node.
    #	id, name	the phase; on each node it is named "<name> <node>".
    #	script		the phase script; it returns {rc detail}.
    #
    # Results:
    #	None.
    #
    # Side effects:
    #	Sets varName in the caller, runs script, and records a phase (or a
    #	SKIP) per node in the table.

    method EachNode {varName id name script} {
        upvar 1 $varName node
        dict for {key node} $nodes {
            uplevel 1 [list $node phase $id "$name $key" $script]
        }
    }
}

# main --
#
#	Runs the pair lifecycle.
#
# Arguments:
#	configFile	the path of config.json.
#
# Results:
#	The exit code: 0 if every phase passed, otherwise 1.
#
# Side effects:
#	Those of Pair run; both guests are stopped at the end.

proc main {configFile} {
    set pair [Pair new $configFile]
    try {
        return [$pair run]
    } finally {
        $pair destroy
    }
}

exit [main {*}$argv]
