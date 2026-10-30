# vm-matrix.tcl --
#
#	homa-vm-matrix: runs every VM test (each kernel's smoke test,
#	lifecycle and pair lifecycle, and each server/client pair) in
#	parallel, then prints a summary table, also written to summary.md:
#
#	    | Test | Kernel(s) | Verdict | Time (s) | Echo | GRO calls | ...
#
#	    vm-matrix.tcl config.json
#
#	config.json (written by host/matrix.nix) lists the tests, each
#	{name kernels exe}, and gives echoRpcs (how many echo RPCs each test
#	sends). Each test runs in its own directory, $HOMA_VM_LOGDIR/<name>/
#	(the tests share nothing on the host), with its output in <name>.out.
#	HOMA_VM_JOBS caps how many run at once (default: all). Exits 1 if any
#	test fails.

package require homa::lc
package require json
namespace import ::homa::lc::report

# main --
#
#	Runs the tests and returns the exit code.

proc main {configFile} {
    global env
    set config [json::json2dict [homa::lc::slurp $configFile]]
    set tests [dict get $config tests]
    set count [llength $tests]
    set logdir [homa::lc::logdir]
    set jobs $count
    if {[info exists env(HOMA_VM_JOBS)] && $env(HOMA_VM_JOBS) ne ""} {
        set jobs $env(HOMA_VM_JOBS)
    }
    puts "VM matrix: $count tests, up to $jobs at once; logs in $logdir"

    set start [clock seconds]
    set batch [homa::lc::Batch new $logdir $jobs]
    try {
        set results [$batch run $tests]
    } finally {
        $batch destroy
    }

    set rows [list \
        "| Test | Kernel(s) | Verdict | Time (s) | Echo | GRO calls | Homa Kops/s\
            | Homa P50 / P99 (us) | TCP Kops/s | TCP P50 / P99 (us) |" \
        "|---|---|---|---|---|---|---|---|---|---|"]
    set failed 0
    foreach test $tests {
        set name [dict get $test name]
        lassign [dict get $results $name] - secs
        set outcome [report matrixRow $name [dict get $test kernels] $secs \
            [dict get $config echoRpcs] [homa::lc::slurp [file join $logdir $name.out]]]
        if {[dict get $outcome verdict] ne "PASS"} {
            incr failed
        }
        lappend rows [dict get $outcome row]
    }
    set summary [file join $logdir summary.md]
    homa::lc::spit $summary [join $rows \n]
    puts "\n[join $rows \n]\n"
    puts "summary: $summary ([expr {[clock seconds] - $start}] s)"
    if {$failed} {
        puts "VERDICT: FAIL ($failed of $count)"
        return 1
    }
    puts "VERDICT: PASS ($count of $count)"
    return 0
}

exit [main {*}$argv]
