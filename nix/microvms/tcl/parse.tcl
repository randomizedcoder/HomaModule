# parse.tcl --
#
#	Pure functions used by the lifecycle drivers: reading guest output
#	(dmesg, tc, Homa's counters, cp_node's stats) and formatting results.
#	Nothing here touches a console, a file or the clock, so tests/parse.test
#	covers all of it with tables.
#
#	Every command is a subcommand of the ensemble homa::lc::parse, e.g.
#	"parse field $line P99" after "namespace import homa::lc::parse".

package require Tcl 8.6-

namespace eval ::homa::lc {
    namespace export parse
}
namespace eval ::homa::lc::parse {
    namespace export firstLine lastLine lines countLines verdict combine \
        phaseLine tableRow firstKernelLine oops smokeDetail snap delta get \
        deltaLine field positive trafficFailures netemSent dropRate \
        netemLimitOk netemDetail matrixRow
    namespace ensemble create

    # Kernel messages that fail the dmesg and serial-log phases.
    variable oopsRe {BUG:|Oops|WARNING:|KASAN|UBSAN|general protection fault|list_add corruption}

    # Shown in a table cell when a value is missing.
    variable dash —
}

# ---- Text ------------------------------------------------------------------------

# homa::lc::parse::firstLine --
#
#	Returns the first line of text (empty if text is empty).

proc ::homa::lc::parse::firstLine {text} {
    return [lindex [split $text \n] 0]
}

# homa::lc::parse::lastLine --
#
#	Returns the last non-empty line of text, or an empty string.

proc ::homa::lc::parse::lastLine {text} {
    return [lindex [lsearch -all -inline -not -exact [split $text \n] {}] end]
}

# homa::lc::parse::lines --
#
#	Splits text into its lines. Unlike split alone, trailing newlines do not
#	start more (empty) lines.

proc ::homa::lc::parse::lines {text} {
    return [split [string trimright $text \n] \n]
}

# homa::lc::parse::countLines --
#
#	Returns how many lines of text match the regular expression re.

proc ::homa::lc::parse::countLines {re text} {
    return [llength [lsearch -all -regexp [split $text \n] $re]]
}

# ---- Phase results ---------------------------------------------------------------

# homa::lc::parse::verdict --
#
#	Maps a phase's result to PASS, SKIP or FAIL.
#
# Arguments:
#	rc	0, any other exit status, or "skip".

proc ::homa::lc::parse::verdict {rc} {
    if {$rc eq "skip"} {
        return SKIP
    }
    if {![string is entier -strict $rc]} {
        return -code error "bad rc \"$rc\""
    }
    return [expr {$rc == 0 ? "PASS" : "FAIL"}]
}

# homa::lc::parse::combine --
#
#	Combines the results of several commands in one phase: returns next if
#	it failed (is not 0), else rc. Folded over the commands, this gives the
#	last failure, or 0.

proc ::homa::lc::parse::combine {rc next} {
    return [expr {$next == 0 ? $rc : $next}]
}

# homa::lc::parse::phaseLine --
#
#	Returns the progress line printed when a phase ends.

proc ::homa::lc::parse::phaseLine {phase name verdict ms detail} {
    set line "  phase $phase $name: $verdict ($ms ms)"
    if {$detail ne ""} {
        append line ": $detail"
    }
    return $line
}

# homa::lc::parse::tableRow --
#
#	Returns a phase's row in summary.md (a Markdown table).

proc ::homa::lc::parse::tableRow {phase name verdict ms detail} {
    set detail [string map {| \\|} $detail]
    return "| $phase | $name | $verdict | $ms | $detail |"
}

# ---- Guest output --------------------------------------------------------------

# homa::lc::parse::firstKernelLine --
#
#	Returns the timestamp of the first kernel message in a serial log, e.g.
#	"[    2.179107]", or an empty string if the kernel has printed nothing yet.

proc ::homa::lc::parse::firstKernelLine {text} {
    if {[regexp -line {^\[ *[0-9]+\.[0-9]+\]} $text stamp]} {
        return $stamp
    }
    return {}
}

# homa::lc::parse::oops --
#
#	Returns the lines of text that report a kernel bug or warning.
#
# Arguments:
#	text	dmesg or serial console output.
#	also	a regular expression for more lines to return with them, in
#		order (e.g. "RIP:", which names the faulting function).

proc ::homa::lc::parse::oops {text {also {}}} {
    variable oopsRe
    set re [expr {$also eq "" ? $oopsRe : "$oopsRe|$also"}]
    return [lsearch -all -inline -regexp [split $text \n] $re]
}

# homa::lc::parse::smokeDetail --
#
#	Returns the detail for the smoke phase: homa-smoke's last verdict, or the
#	last step it reached when it gave none.
#
# Arguments:
#	text	homa-smoke's output.
#	rc	the console's result for the command.

proc ::homa::lc::parse::smokeDetail {text rc} {
    set verdicts [regexp -all -inline {HOMA_SMOKE_(?:PASS|FAIL:[A-Z_]+)} $text]
    if {[llength $verdicts]} {
        return [lindex $verdicts end]
    }
    set steps [regexp -all -inline {HOMA_SMOKE_[A-Z_]+_OK} $text]
    return "no verdict (rc $rc), last step: [lindex $steps end]"
}

# ---- Counters ----------------------------------------------------------------------

# homa::lc::parse::snap --
#
#	Reads homa-node-stats output ("name value ..." lines) into a dictionary
#	of the given counters, summing repeated names (Homa reports one line per
#	core). Counters that do not appear are 0.
#
# Arguments:
#	text	homa-node-stats output.
#	keys	the counters to keep, in order.

proc ::homa::lc::parse::snap {text keys} {
    set sums [dict create]
    foreach key $keys {
        dict set sums $key 0
    }
    foreach line [split $text \n] {
        # Not lassign: the rest of the line is free text, not a list.
        if {[regexp {^(\S+)\s+(\S+)} $line -> name value]
                && [dict exists $sums $name] && [string is entier -strict $value]} {
            dict incr sums $name $value
        }
    }
    return $sums
}

# homa::lc::parse::delta --
#
#	Returns the counters that changed between two snaps, as after - before.
#	A counter missing from either side counts as 0.

proc ::homa::lc::parse::delta {before after} {
    set moved [dict create]
    foreach key [lsort -unique [concat [dict keys $before] [dict keys $after]]] {
        set diff [expr {[get $after $key] - [get $before $key]}]
        if {$diff != 0} {
            dict set moved $key $diff
        }
    }
    # Keep the first snap's order, then any new counters.
    set ordered [dict create]
    foreach key [concat [dict keys $before] [dict keys $after]] {
        if {[dict exists $moved $key]} {
            dict set ordered $key [dict get $moved $key]
        }
    }
    return $ordered
}

# homa::lc::parse::get --
#
#	Returns counter key from a dictionary of counters, or 0.

proc ::homa::lc::parse::get {counters key} {
    if {[dict exists $counters $key]} {
        return [dict get $counters $key]
    }
    return 0
}

# homa::lc::parse::deltaLine --
#
#	Formats counters as "name=value" pairs for the deltas log.

proc ::homa::lc::parse::deltaLine {counters} {
    return [join [lmap {key value} $counters {string cat $key = $value}]]
}

# ---- cp_node -----------------------------------------------------------------------

# homa::lc::parse::field --
#
#	Returns the word after word in a cp_node stats line (e.g. "clients:" for
#	Kops/s, "P50", "P99"), or missing if there is none.

proc ::homa::lc::parse::field {line word {missing -}} {
    set words [regexp -all -inline {\S+} $line]
    set i [lsearch -exact $words $word]
    if {$i < 0 || $i + 1 >= [llength $words]} {
        return $missing
    }
    return [lindex $words $i+1]
}

# homa::lc::parse::positive --
#
#	Returns 1 if value is a number above zero, 0 otherwise (including "-").

proc ::homa::lc::parse::positive {value} {
    return [expr {[string is double -strict $value] && $value > 0}]
}

# homa::lc::parse::trafficFailures --
#
#	Returns what failed in one traffic run: "echo" unless all six echo RPCs
#	completed, "homa" or "tcp" unless that cp_node run timed any RPC (a P99
#	above 0; at 5 % loss TCP manages so few RPCs that its Kops/s rounds to 0).
#
# Arguments:
#	echoes	how many echo responses arrived.
#	homa	cp_node's last stats line over Homa.
#	tcp	cp_node's last stats line over TCP.

proc ::homa::lc::parse::trafficFailures {echoes homa tcp} {
    set failed {}
    if {$echoes ne "6"} {
        lappend failed echo
    }
    foreach proto {homa tcp} line [list $homa $tcp] {
        if {![positive [field $line P99]]} {
            lappend failed $proto
        }
    }
    return $failed
}

# ---- tc netem ------------------------------------------------------------------------

# homa::lc::parse::netemSent --
#
#	Returns {packets drops} from the netem qdisc in "tc -s qdisc show"
#	output, or an empty list if there is no netem qdisc with counters.

proc ::homa::lc::parse::netemSent {text} {
    set re {^qdisc netem [^\n]*\n Sent \d+ bytes (\d+) pkt \(dropped (\d+),}
    if {[regexp -line -- $re $text -> packets drops]} {
        return [list $packets $drops]
    }
    return {}
}

# homa::lc::parse::dropRate --
#
#	Checks a node's measured netem drop rate against the configured loss.
#	With no loss configured there must be no drops. Otherwise the rate may
#	be up to twice the loss plus half a point (it reads a little low, since
#	tc counts sent packets per GSO segment but drops per skb), and, once
#	there are 10000 packets, must be at least half the loss, so netem is
#	really on. Tail drops would push the rate up; netem's limit prevents
#	them.
#
# Arguments:
#	packets	packets netem sent.
#	drops	packets netem dropped.
#	loss	the configured loss, in percent.
#
# Results:
#	A dictionary: rate (percent, two decimals) and ok (1 or 0).

proc ::homa::lc::parse::dropRate {packets drops loss} {
    foreach count [list $packets $drops] {
        if {![string is entier -strict $count] || $count < 0} {
            return -code error "not a count: \"$count\""
        }
    }
    if {![string is double -strict $loss]} {
        return -code error "not a number: \"$loss\""
    }
    set total [expr {$packets + $drops}]
    set pct [expr {$total ? 100.0 * $drops / $total : 0.0}]
    if {$loss == 0} {
        set pass [expr {$drops == 0}]
    } else {
        set pass [expr {$pct <= 2 * $loss + 0.5
                && ($total < 10000 || $pct >= $loss / 2.0)}]
    }
    return [dict create rate [format %.2f $pct] ok $pass]
}

# homa::lc::parse::netemLimitOk --
#
#	Returns 1 if "tc qdisc show" output has a netem qdisc with exactly the
#	given limit, 0 otherwise.

proc ::homa::lc::parse::netemLimitOk {text limit} {
    if {![string is entier -strict $limit]} {
        return -code error "not a count: \"$limit\""
    }
    return [regexp -line -- "^qdisc netem .*limit ${limit}( |\$)" $text]
}

# homa::lc::parse::netemDetail --
#
#	Returns the netem qdisc's settings from "tc qdisc show" output, without
#	tc's "qdisc netem <handle>: root refcnt <n>" prefix.

proc ::homa::lc::parse::netemDetail {text} {
    set re {^qdisc netem [0-9a-f]*: root refcnt [0-9]* ([^\n]*)}
    if {[regexp -line -- $re $text -> settings]} {
        return $settings
    }
    return {}
}

# ---- homa-vm-matrix --------------------------------------------------------------------

# homa::lc::parse::matrixRow --
#
#	Reads one test's output for homa-vm-matrix's table.
#
# Arguments:
#	name	the test (its package name).
#	kernels	the kernel(s) it ran.
#	secs	how long it took.
#	out	its output. A test passed if a line starts "VERDICT: PASS"; echo,
#		GRO and cp_node figures come from its HOMA_* lines, each optional.
#
# Results:
#	A dictionary: verdict (PASS or FAIL) and row (the Markdown table row).

proc ::homa::lc::parse::matrixRow {name kernels secs out} {
    variable dash
    set result [expr {[regexp -line {^VERDICT: PASS} $out] ? "PASS" : "FAIL"}]
    set echoes 0
    regexp {HOMA_(?:SMOKE|PAIR)_ECHO responses=(\d+)} $out -> echoes
    set gro $dash
    regexp {homa_gro_receive calls=(\d+)} $out -> gro
    set cells [list $name $kernels $result $secs $echoes/6 $gro]
    foreach proto {homa tcp} {
        set line [lindex [regexp -all -inline -line "HOMA_PAIR_CPNODE_$proto .*" $out] end]
        lappend cells [field $line clients: $dash] \
            "[field $line P50 $dash] / [field $line P99 $dash]"
    }
    return [dict create verdict $result row "| [join $cells { | }] |"]
}

package provide homa::lc::parse 1.0
