# all.tcl --
#
#	Runs every *.test file in this directory, in this interpreter.
#
#	    tclsh all.tcl ?tcltest options?
#
#	For example "-file parse.test" runs just the pure tables, which is what
#	the Tcl 9 run does (Expect is built for Tcl 8.6 only). Exits non-zero
#	if any test fails.

package require tcltest 2
encoding system utf-8

tcltest::configure -testdir [file dirname [file normalize [info script]]] \
    -singleproc 1 {*}$argv

# runAllTests returns normally even when tests fail; count failures from its
# report instead.
set failed 0
proc tcltest::cleanupTestsHook {} {
    variable numTests
    incr ::failed $numTests(Failed)
}
tcltest::runAllTests
exit [expr {$failed > 0}]
