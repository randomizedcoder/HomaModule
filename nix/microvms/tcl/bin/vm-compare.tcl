# vm-compare.tcl --
#
#	homa-vm-compare: compares two homa-vm-matrix runs, test by test, by
#	what two good runs share: each phase's id, name and verdict, the
#	HOMA_* lines with their numbers masked, and the VERDICT lines (see
#	"parse shape"). Times, details and counters are ignored. Use it after
#	changing a driver, against the logs of a run from before the change:
#
#	    vm-compare.tcl old-logdir new-logdir
#
#	Each log directory is a matrix run's $HOMA_VM_LOGDIR, holding one
#	<test>.out per test. Prints each test's changes, "-" for a line only
#	in old and "+" for one only in new. Exits 0 if every test is the same,
#	1 if any differs or is missing from one side, 2 on a usage error.

package require homa::lc
namespace import ::homa::lc::parse ::homa::lc::report

# compare --
#
#	Compares the runs.
#
# Arguments:
#	old	the old run's log directory.
#	new	the new run's log directory.
#
# Results:
#	The exit code: 0 if every test is the same, 1 if not, 2 if a log
#	directory is missing or holds no <test>.out files.
#
# Side effects:
#	Reads the <test>.out files and prints each test's result and the
#	verdict.

proc compare {old new} {
    set dirs [list $old $new]
    foreach dir $dirs {
        if {![file isdirectory $dir]} {
            puts stderr "homa-vm-compare: $dir: not a directory"
            return 2
        }
    }
    set names {}
    foreach dir $dirs {
        foreach path [glob -nocomplain -directory $dir *.out] {
            lappend names [file rootname [file tail $path]]
        }
    }
    set names [lsort -unique $names]
    if {![llength $names]} {
        puts stderr "homa-vm-compare: no <test>.out files in [join $dirs { or }]"
        return 2
    }

    set differ 0
    foreach name $names {
        set shapes {}
        foreach dir $dirs {
            set path [file join $dir $name.out]
            if {[file exists $path]} {
                lappend shapes [parse shape [homa::lc::readFile $path]]
            }
        }
        if {[llength $shapes] < 2} {
            set side [expr {[file exists [file join $old $name.out]] ? "old" : "new"}]
            puts "$name: only in $side"
            incr differ
            continue
        }
        set changes [report diff {*}$shapes]
        if {![llength $changes]} {
            puts "$name: same ([llength [lindex $shapes 1]] lines)"
            continue
        }
        puts "$name: differs"
        foreach change $changes {
            puts "    $change"
        }
        incr differ
    }
    set count [llength $names]
    if {$differ} {
        puts "VERDICT: FAIL ($differ of $count differ)"
        return 1
    }
    puts "VERDICT: PASS ($count of $count the same)"
    return 0
}

if {[llength $argv] != 2} {
    puts stderr "usage: homa-vm-compare old-logdir new-logdir"
    exit 2
}
exit [compare {*}$argv]
