# report.tcl --
#
#	Pure functions that format what the drivers print and write: phase
#	verdicts, progress lines and summary.md rows, counter deltas, and
#	homa-vm-matrix's table rows. tests/report.test covers them with tables.
#
#	Every command is a subcommand of the ensemble homa::lc::report, e.g.
#	"report phaseLine ..." after "namespace import homa::lc::report".

package require Tcl 8.6-
package require homa::lc::parse

namespace eval ::homa::lc {
    namespace export report
}
namespace eval ::homa::lc::report {
    namespace export verdict combine phaseLine tableRow deltaLine matrixRow
    namespace ensemble create
    # Find parse (for field).
    namespace path ::homa::lc

    # Shown in a table cell when a value is missing.
    variable dash —
}

# ---- Phase results -----------------------------------------------------------

# homa::lc::report::verdict --
#
#	Maps a phase's result to PASS, SKIP or FAIL.
#
# Arguments:
#	rc	0, any other exit status, or "skip".

proc ::homa::lc::report::verdict {rc} {
    if {$rc eq "skip"} {
        return SKIP
    }
    if {![string is entier -strict $rc]} {
        return -code error "bad rc \"$rc\""
    }
    return [expr {$rc == 0 ? "PASS" : "FAIL"}]
}

# homa::lc::report::combine --
#
#	Combines the results of several commands in one phase: returns next if
#	it failed (is not 0), else rc. Folded over the commands, this gives the
#	last failure, or 0.

proc ::homa::lc::report::combine {rc next} {
    foreach value [list $rc $next] {
        if {![string is entier -strict $value]} {
            return -code error "bad rc \"$value\""
        }
    }
    return [expr {$next == 0 ? $rc : $next}]
}

# homa::lc::report::phaseLine --
#
#	Returns the progress line printed when a phase ends.

proc ::homa::lc::report::phaseLine {phase name verdict ms detail} {
    set line "  phase $phase $name: $verdict ($ms ms)"
    if {$detail ne ""} {
        append line ": $detail"
    }
    return $line
}

# homa::lc::report::tableRow --
#
#	Returns a phase's row in summary.md (a Markdown table).

proc ::homa::lc::report::tableRow {phase name verdict ms detail} {
    set detail [string map {| \\|} $detail]
    return "| $phase | $name | $verdict | $ms | $detail |"
}

# ---- Counters --------------------------------------------------------------------

# homa::lc::report::deltaLine --
#
#	Formats counters as "name=value" pairs for the deltas log.

proc ::homa::lc::report::deltaLine {counters} {
    return [join [lmap {key value} $counters {string cat $key = $value}]]
}

# ---- homa-vm-matrix --------------------------------------------------------------------

# homa::lc::report::matrixRow --
#
#	Reads one test's output for homa-vm-matrix's table.
#
# Arguments:
#	name	the test (its package name).
#	kernels	the kernel(s) it ran.
#	secs	how long it took.
#	want	how many echo RPCs a test sends (constants.echoRpcs).
#	out	its output. A test passed if a line starts "VERDICT: PASS"; echo,
#		GRO and cp_node figures come from its HOMA_* lines, each optional.
#
# Results:
#	A dictionary: verdict (PASS or FAIL) and row (the Markdown table row).

proc ::homa::lc::report::matrixRow {name kernels secs want out} {
    variable dash
    set result [expr {[regexp -line {^VERDICT: PASS} $out] ? "PASS" : "FAIL"}]
    set echoes 0
    regexp {HOMA_(?:SMOKE|PAIR)_ECHO responses=(\d+)} $out -> echoes
    set gro $dash
    regexp {homa_gro_receive calls=(\d+)} $out -> gro
    set cells [list $name $kernels $result $secs $echoes/$want $gro]
    foreach proto {homa tcp} {
        set line [lindex [regexp -all -inline -line "HOMA_PAIR_CPNODE_$proto .*" $out] end]
        lappend cells [parse field $line clients: $dash] \
            "[parse field $line P50 $dash] / [parse field $line P99 $dash]"
    }
    return [dict create verdict $result row "| [join $cells { | }] |"]
}

package provide homa::lc::report 1.0
