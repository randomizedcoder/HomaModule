# lifecycle.tcl --
#
#	The single-VM lifecycle test (homa-lifecycle): boots one guest and
#	drives it over its consoles, phase by phase, each with a timeout and a
#	time:
#
#	    1   start       qemu running, console ports listening
#	    2   serial      first kernel line in serial.log (ttyS0)
#	    2b  virtio      a root shell answering on hvc0
#	    3   smoke       homa-smoke: insmod, echo, GRO/RPS, rmmod
#	    4   cycles      insmod / netns add+del / rmmod, moduleCycles times
#	    5   dmesg       no BUG/Oops/WARNING/KASAN/UBSAN in dmesg
#	    6   shutdown    poweroff over hvc0
#	    7   exit        qemu exits
#	    8   serial-log  no oops anywhere in serial.log
#
#	    lifecycle.tcl config.json
#
#	config.json (written by host/lifecycle.nix) holds the label, the
#	timeouts, moduleCycles and the guest's runner and console ports. Logs
#	go to $HOMA_VM_LOGDIR (default: a new temporary directory), which is
#	also QEMU's working directory. Exits 1 if any phase fails.

package require homa::lc
package require json
namespace import ::homa::lc::parse

# main --
#
#	Runs the phases and returns the exit code.

proc main {configFile} {
    set config [json::json2dict [homa::lc::slurp $configFile]]
    set logdir [homa::lc::logdir]
    cd $logdir
    puts "lifecycle[dict get $config label]: logs in $logdir"

    set table [homa::lc::Table new]
    set vm [homa::lc::Node new $table . [dict get $config vm] [dict get $config timeouts]]
    try {
        $vm start 1
        $vm serial 2
        $vm virtio 2b
        $vm phase 3 smoke {
            set result [$vm run smoke.log [dict get $config timeouts smoke] {homa-smoke 2>&1}]
            set text [dict get $result out]
            foreach line [lsearch -all -inline [split $text \n] *HOMA_SMOKE_*] {
                puts "    $line"
            }
            list [dict get $result rc] [parse smokeDetail $text [dict get $result rc]]
        }
        # One line (a multi-line command would bring the shell's continuation
        # prompts), in a subshell, so a failure ends the loop but not the
        # shell.
        set count [dict get $config moduleCycles]
        set steps {
            {insmod "$HOMA_KO"}
            {ip netns add homa-lc}
            {ip netns exec homa-lc ip link set lo up}
            {ip netns del homa-lc}
            {rmmod homa}
            {echo cycle $i ok}
        }
        $vm phase 4 cycles {
            set loop [format {(set -e; for i in $(seq %d); do %s; done) 2>&1} \
                $count [join $steps "; "]]
            set result [$vm run cycles.log [dict get $config timeouts cycles] $loop]
            set done [parse countLines {^cycle .* ok$} [dict get $result out]]
            list [dict get $result rc] "$done of $count"
        }
        $vm dmesg 5
        $vm shutdown 6
        $vm waitExit 7
        $vm serialLog 8
        return [$table verdict]
    } finally {
        $vm destroy
        $table destroy
    }
}

exit [main {*}$argv]
