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
    namespace export verdict combine phaseLine tableRow deltaLine trafficDetail matrixRow diff
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
#
# Results:
#	PASS, SKIP or FAIL. An error if rc is neither an integer nor "skip".
#
# Side effects:
#	None.

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
#	Combines the results of several commands in one phase. Folded over the
#	commands, this gives the last failure, or 0.
#
# Arguments:
#	rc	the result so far.
#	next	the next command's exit status.
#
# Results:
#	next if it failed (is not 0), else rc. An error if either is not an
#	integer.
#
# Side effects:
#	None.

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
#
# Arguments:
#	phase	the phase's number.
#	name	the phase's name.
#	verdict	PASS, SKIP or FAIL.
#	ms	how long it took, in milliseconds.
#	detail	what to add after the verdict, or "".
#
# Results:
#	The line, e.g. "  phase 3 smoke: PASS (120 ms): ...".
#
# Side effects:
#	None.

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
#
# Arguments:
#	phase	the phase's number.
#	name	the phase's name.
#	verdict	PASS, SKIP or FAIL.
#	ms	how long it took, in milliseconds.
#	detail	the phase's detail; any "|" in it is escaped.
#
# Results:
#	The Markdown table row.
#
# Side effects:
#	None.

proc ::homa::lc::report::tableRow {phase name verdict ms detail} {
    set detail [string map {| \\|} $detail]
    return "| $phase | $name | $verdict | $ms | $detail |"
}

# ---- Counters --------------------------------------------------------------------

# homa::lc::report::deltaLine --
#
#	Formats counters for the deltas log.
#
# Arguments:
#	counters	a dictionary of counter name -> value.
#
# Results:
#	The counters as space-separated "name=value" pairs.
#
# Side effects:
#	None.

proc ::homa::lc::report::deltaLine {counters} {
    return [join [lmap {key value} $counters {string cat $key = $value}]]
}

# ---- Traffic runs ------------------------------------------------------------------

# homa::lc::report::trafficDetail --
#
#	Judges and describes one pair traffic run (echo, cp_node over Homa and
#	TCP, counter deltas, netem drops).
#
# Arguments:
#	measured	a dictionary: echoes (responses that arrived), homa and
#			tcp (cp_node's last stats lines), deltas (node name ->
#			counter deltas) and checks (node name -> parse
#			netemCheck's result; empty without netem).
#	want		how many echo RPCs were sent (constants.echoRpcs).
#	must		a counter that must have gone up, summed over the nodes,
#			or "".
#
# Results:
#	A dictionary: failed (what failed, from parse trafficFailures, then
#	drops-<node> and no-<counter>) and detail (the phase's detail).
#
# Side effects:
#	None.

proc ::homa::lc::report::trafficDetail {measured want must} {
    lassign [lmap key {echoes homa tcp deltas checks} {dict get $measured $key}] \
        echoes homa tcp deltas checks
    set failures [parse trafficFailures $want $echoes $homa $tcp]
    set text [format "echo %s/%s; Homa %s Kops P50 %s P99 %s us; TCP %s Kops P99 %s us" \
        $echoes $want [parse field $homa clients:] [parse field $homa P50] \
        [parse field $homa P99] [parse field $tcp clients:] [parse field $tcp P99]]
    if {[dict size $checks]} {
        append text "; netem drops [join [lmap {node check} $checks {dict get $check report}]]"
        dict for {node check} $checks {
            if {![dict get $check ok]} {
                lappend failures drops-$node
            }
        }
    }
    append text [format "; RESENDs %d, resent %d, rpc_timeouts %d, tcp_retrans %d" \
        [sum $deltas packets_sent_RESEND] [sum $deltas resent_packets] \
        [sum $deltas rpc_timeouts] [sum $deltas tcp_retrans]]
    if {$must ne ""} {
        set count [sum $deltas $must]
        append text "; $must $count"
        if {$count <= 0} {
            lappend failures no-$must
        }
    }
    if {[llength $failures]} {
        append text "; failed: [join $failures]"
    }
    return [dict create failed $failures detail $text]
}

# homa::lc::report::sum --
#
#	Sums one counter over every node's deltas.
#
# Arguments:
#	deltas	a dictionary of node name -> counters.
#	key	the counter's name.
#
# Results:
#	Counter key summed over the nodes; 0 if there are none.
#
# Side effects:
#	None.

proc ::homa::lc::report::sum {deltas key} {
    return [tcl::mathop::+ {*}[lmap {node counters} $deltas {parse get $counters $key}]]
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
#
# Side effects:
#	None.

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

# ---- homa-vm-compare -----------------------------------------------------------------

# homa::lc::report::diff --
#
#	Lists the changes between two lists of lines, by their longest common
#	subsequence (the lists are a run's phase lines: a hundred or so).
#
# Arguments:
#	old	the lines before.
#	new	the lines after.
#
# Results:
#	The changes in order, each "- <line>" (only in old) or "+ <line>"
#	(only in new), removals before additions where a line was replaced;
#	an empty list if the lists are equal.
#
# Side effects:
#	None.

proc ::homa::lc::report::diff {old new} {
    set n [llength $old]
    set m [llength $new]
    # common(i,j): the length of the longest common subsequence of
    # old[i..] and new[j..].
    for {set i $n} {$i >= 0} {incr i -1} {
        for {set j $m} {$j >= 0} {incr j -1} {
            if {$i == $n || $j == $m} {
                set common($i,$j) 0
            } elseif {[lindex $old $i] eq [lindex $new $j]} {
                set common($i,$j) [expr {$common([expr {$i + 1}],[expr {$j + 1}]) + 1}]
            } else {
                set common($i,$j) [expr {max($common([expr {$i + 1}],$j),
                    $common($i,[expr {$j + 1}]))}]
            }
        }
    }
    set changes {}
    set i 0
    set j 0
    while {$i < $n && $j < $m} {
        if {[lindex $old $i] eq [lindex $new $j]} {
            incr i
            incr j
        } elseif {$common([expr {$i + 1}],$j) >= $common($i,[expr {$j + 1}])} {
            lappend changes "- [lindex $old $i]"
            incr i
        } else {
            lappend changes "+ [lindex $new $j]"
            incr j
        }
    }
    foreach line [lrange $old $i end] {
        lappend changes "- $line"
    }
    foreach line [lrange $new $j end] {
        lappend changes "+ $line"
    }
    return $changes
}

package provide homa::lc::report 1.0
