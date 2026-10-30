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

namespace eval pair {
    # config	the parsed config.json.
    # table	the run's homa::lc::Table.
    # nodes	node name -> homa::lc::Node, for node0 and node1.
    # timeout	seconds for an ordinary command.
    variable config table nodes timeout
}
# For nagelfar: the type of table, so it checks the phase scripts.
##nagelfar implicitvarns pair table\ _obj,Table

# pair::node --
#
#	Returns the homa::lc::Node called name (node0 or node1).

proc pair::node {name} {
    variable nodes
    return [dict get $nodes $name]
}

# pair::bothShells --
#
#	Returns 1 if both nodes' shells answer; otherwise SKIPs the phase and
#	returns 0.

proc pair::bothShells {id name} {
    variable table
    if {[[node node0] shell] && [[node node1] shell]} {
        return 1
    }
    $table skip $id $name [format "no shell on hvc0 (node0 %d, node1 %d)" \
        [[node node0] shell] [[node node1] shell]]
    return 0
}

# pair::eachNode --
#
#	Runs a phase on each node that has a shell, as "<name> node<i>", like
#	foreach: script runs in the caller's scope with varName set to the
#	homa::lc::Node, and returns {rc detail}.

##nagelfar syntax pair::eachNode n x x c
proc pair::eachNode {varName id name script} {
    variable table
    variable nodes
    upvar 1 $varName node
    dict for {key node} $nodes {
        if {[$node need $id "$name $key"]} {
            uplevel 1 [list $table phase $id "$name $key" $script]
        }
    }
}

# pair::onBoth --
#
#	Runs one command on both nodes as a single phase. The detail is given,
#	or else node1's output on one line.

proc pair::onBoth {id name log cmd {detail {}}} {
    variable table
    variable nodes
    variable timeout
    if {![bothShells $id $name]} {
        return
    }
    $table phase $id $name {
        set rc 0
        dict for {key node} $nodes {
            set result [$node run $log $timeout $cmd]
            set rc [report combine $rc [dict get $result rc]]
        }
        if {$detail eq ""} {
            set detail [regsub -all { +} [string map {\n " "} [dict get $result out]] " "]
        }
        list $rc $detail
    }
}

# pair::cpNode --
#
#	Returns the command for one cp_node client run over proto (homa or
#	tcp), which prints cp_node's last stats line. Output goes to a file,
#	grepped afterwards: under the console shell's job control, timeout's
#	SIGTERM also reaches the rest of a pipeline, losing its output.

proc pair::cpNode {proto} {
    variable config
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

# pair::sum --
#
#	Returns counter key summed over both nodes' deltas (a dictionary of
#	node name -> counters).

proc pair::sum {deltas key} {
    return [tcl::mathop::+ {*}[lmap {name counters} $deltas {parse get $counters $key}]]
}

# pair::traffic --
#
#	One traffic run from node1 to node0: echo, then cp_node over Homa and
#	over TCP, with counter deltas on both nodes.
#
# Arguments:
#	id, name	the phase; it is named "traffic <name>".
#	loss		netem's configured loss in percent, or "" without
#			netem. With netem, each node's measured drop rate is
#			checked against it.
#	must		a counter that must have moved (summed over both
#			nodes), or "": packets_sent_RESEND under loss, the
#			qdisc and pacer counters with Homa's qdisc.

proc pair::traffic {id name {loss {}} {must {}}} {
    variable config
    variable table
    variable nodes
    variable timeout
    if {![bothShells $id "traffic $name"]} {
        return
    }
    $table phase $id "traffic $name" {
        set dir [file join [pwd] traffic $name]
        file mkdir $dir
        set metrics [dict get $config metrics]
        set peer [dict get $config peer]
        set client [node node1]
        set rc 0
        set before [dict create]
        dict for {key node} $nodes {
            set result [$node run [file join $dir $key-stats0] $timeout homa-node-stats]
            set rc [report combine $rc [dict get $result rc]]
            dict set before $key [parse snap [dict get $result out] $metrics]
        }

        set echoTimeout [dict get $config timeouts echo]
        set echoes [parse lastLine [dict get [$client run [file join $dir echo.log] $echoTimeout \
            "timeout [expr {$echoTimeout - 10}] demo_client1 $peer 4000 > /tmp/echo.out\
            2>&1 < /dev/null; grep -c '^Received response' /tmp/echo.out"] out]]
        foreach proto {homa tcp} {
            set stats($proto) [parse lastLine [dict get \
                [$client run [file join $dir $proto.log] $timeout [cpNode $proto]] out]]
        }

        set deltas [dict create]
        set deltaLines {}
        dict for {key node} $nodes {
            set result [$node run [file join $dir $key-stats1] $timeout homa-node-stats]
            set rc [report combine $rc [dict get $result rc]]
            dict set deltas $key [parse delta [dict get $before $key] \
                [parse snap [dict get $result out] $metrics]]
            lappend deltaLines "$key: [report deltaLine [dict get $deltas $key]]"
        }
        homa::lc::spit [file join $dir deltas] [join $deltaLines \n]

        set want [dict get $config echoRpcs]
        set failed [parse trafficFailures $want $echoes $stats(homa) $stats(tcp)]
        set drops {}
        if {$loss ne ""} {
            set dropReport {}
            dict for {key node} $nodes {
                set out [dict get [$node run [file join $dir $key-tc] $timeout \
                    "tc -s qdisc show dev eth1"] out]
                lassign [parse netemSent $out] packets dropped
                set measured [parse dropRate [expr {$packets eq "" ? 0 : $packets}] \
                    [expr {$dropped eq "" ? 0 : $dropped}] $loss]
                set total [expr {$packets eq "" ? 0 : $packets + $dropped}]
                lappend dropReport [format "%s %s/%s (%s%%)" $key \
                    [expr {$dropped eq "" ? "?" : $dropped}] $total [dict get $measured rate]]
                if {![dict get $measured ok]} {
                    lappend failed drops-$key
                }
            }
            set drops "; netem drops [join $dropReport]"
        }
        set moved {}
        if {$must ne ""} {
            set count [sum $deltas $must]
            if {$count <= 0} {
                lappend failed no-$must
            }
            set moved "; $must $count"
        }
        if {[llength $failed]} {
            set rc 1
        }

        if {$name eq "baseline"} {
            # The lines homa-vm-matrix puts in its table.
            puts "HOMA_PAIR_ECHO responses=$echoes (want $want)"
            puts "HOMA_PAIR_CPNODE_homa $stats(homa)"
            puts "HOMA_PAIR_CPNODE_tcp $stats(tcp)"
        }
        foreach line $deltaLines {
            puts "    $line"
        }
        set detail [format "echo %s/%s; Homa %s Kops P50 %s P99 %s us; TCP %s Kops P99 %s us%s" \
            $echoes $want [parse field $stats(homa) clients:] [parse field $stats(homa) P50] \
            [parse field $stats(homa) P99] [parse field $stats(tcp) clients:] \
            [parse field $stats(tcp) P99] $drops]
        append detail [format "; RESENDs %d, resent %d, rpc_timeouts %d, tcp_retrans %d%s" \
            [sum $deltas packets_sent_RESEND] [sum $deltas resent_packets] \
            [sum $deltas rpc_timeouts] [sum $deltas tcp_retrans] $moved]
        if {[llength $failed]} {
            append detail "; failed: [join $failed]"
        }
        list $rc $detail
    }
}

# pair::netem --
#
#	Replaces eth1's root qdisc with netem on both nodes, so its counters
#	start from zero, and checks that the limit took.

proc pair::netem {id name netemArgs} {
    variable config
    variable table
    variable nodes
    variable timeout
    if {![bothShells $id "netem $name"]} {
        return
    }
    set limit [dict get $config netem limit]
    $table phase $id "netem $name" {
        set rc 0
        dict for {key node} $nodes {
            set result [$node run netem-$name.log $timeout [join [list \
                {tc qdisc del dev eth1 root 2> /dev/null} \
                "tc qdisc add dev eth1 root netem $netemArgs && tc qdisc show dev eth1"] "; "]]
            if {[dict get $result rc] || ![parse netemLimitOk [dict get $result out] $limit]} {
                set rc 1
            }
        }
        list $rc [parse netemDetail [dict get $result out]]
    }
}

# pair::main --
#
#	Runs the phases and returns the exit code.

proc pair::main {configFile} {
    variable config
    variable table
    variable nodes
    variable timeout
    set config [json::json2dict [homa::lc::slurp $configFile]]
    set timeout [dict get $config timeouts command]
    set logdir [homa::lc::logdir]
    cd $logdir
    puts "pair lifecycle[dict get $config label]: logs in $logdir"

    set table [homa::lc::Table new]
    set nodes [dict create]
    foreach key {node0 node1} {
        dict set nodes $key [homa::lc::Node new $table [dict merge [dict get $config $key] \
            [dict create dir $key timeouts [dict get $config timeouts]]] " $key"]
    }
    try {
        foreach step {start serial virtio} phase {1 2 3} {
            dict for {key node} $nodes {
                $node $step $phase
            }
        }

        eachNode node 4 insmod {
            set result [$node run insmod.log $timeout {insmod "$HOMA_KO" 2>&1}]
            list [dict get $result rc] [parse firstLine [dict get $result out]]
        }

        set peer [dict get $config peer]
        set client [node node1]
        set server [node node0]
        if {[$client need 5 link]} {
            $table phase 5 link {
                set result [$client run ping.log $timeout "for i in \$(seq 20); do ping -c 1\
                    -W 1 $peer > /dev/null && break; done; ping -q -c 3 -W 2 $peer"]
                set summary [lsearch -all -inline -regexp [split [dict get $result out] \n] \
                    {packet loss|rtt}]
                list [dict get $result rc] [join $summary " "]
            }
        }

        # Each server in a subshell, so the console's shell has no jobs to
        # report.
        if {[$server need 6 servers]} {
            set homaPort [dict get $config cpNode homaPort]
            $table phase 6 servers {
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
        }

        traffic 7 baseline
        set i 0
        foreach impairment [dict get $config netem phases] {
            lassign [lmap key {name args loss} {dict get $impairment $key}] name netemArgs loss
            incr i
            netem 8.$i $name $netemArgs
            traffic 8.$i $name $loss [expr {$loss == 0 ? "" : "packets_sent_RESEND"}]
        }
        onBoth 9 "netem clear" netem-clear.log \
            "tc qdisc del dev eth1 root && ! tc qdisc show dev eth1 | grep -q netem" \
            "default qdisc on eth1"
        traffic 9 recovered

        # The pacer works from the link speed. virtio-net reports none
        # (SPEED_UNKNOWN: round-4 candidate 5), so phase 11 sets
        # net.homa.link_mbps, which the qdisc then uses, low enough that the
        # pacer has to defer packets.
        onBoth 10 "qdisc homa" qdisc-on.log [join {
            {sysctl -n net.homa.link_mbps > /tmp/link_mbps}
            {homa-qdisc on > /tmp/qdisc.out && head -n 1 /tmp/qdisc.out\
                && grep '^qdisc homa' /tmp/qdisc.out}
        } "; "]
        traffic 10 homa-qdisc "" qdisc_tcp_packets
        onBoth 11 "qdisc paced" qdisc-paced.log \
            "sysctl -w net.homa.link_mbps=[dict get $config pacedMbps]"
        traffic 11 homa-qdisc-paced "" pacer_homa_packets
        onBoth 12 "qdisc off" qdisc-off.log [join {
            {sysctl -w net.homa.link_mbps=$(cat /tmp/link_mbps)}
            {homa-qdisc off}
            {! tc qdisc show dev eth1 | grep -q '^qdisc homa'}
        } " && "]

        if {[$server need 13 "stop servers"]} {
            $table phase 13 "stop servers" {
                set result [$server run servers.log $timeout [join {
                    {pkill -x demo_server1} {pkill -x cp_node} {sleep 1}
                    {! pgrep -x 'demo_server1|cp_node'}
                } "; "] a]
                list [dict get $result rc] ""
            }
        }

        eachNode node 14 rmmod {
            set result [$node run rmmod.log $timeout {rmmod homa 2>&1}]
            list [dict get $result rc] [parse firstLine [dict get $result out]]
        }
        foreach step {dmesg shutdown waitExit serialLog} phase {15 16 17 18} {
            dict for {key node} $nodes {
                $node $step $phase
            }
        }
        return [$table verdict]
    } finally {
        dict for {key node} $nodes {
            $node destroy
        }
    }
}

exit [pair::main {*}$argv]
