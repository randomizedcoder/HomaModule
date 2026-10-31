# pkgIndex.tcl --
#
#	homa::lc::parse, report and protocol are pure Tcl (8.6 or 9).
#	homa::lc::console and homa::lc (the phase table and the guest nodes)
#	need Expect, which is built for Tcl 8.6.

package ifneeded homa::lc::parse 1.0 [list source -encoding utf-8 [file join $dir parse.tcl]]
package ifneeded homa::lc::report 1.0 [list source -encoding utf-8 [file join $dir report.tcl]]
package ifneeded homa::lc::protocol 1.0 [list source -encoding utf-8 [file join $dir protocol.tcl]]
package ifneeded homa::lc::console 1.0 [list source -encoding utf-8 [file join $dir console.tcl]]
package ifneeded homa::lc 1.0 [list source -encoding utf-8 [file join $dir lc.tcl]]
