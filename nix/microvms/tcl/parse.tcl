# parse.tcl --
#
#	Pure functions used by the lifecycle drivers to read guest output:
#	dmesg, tc, Homa's counters, cp_node's stats. report.tcl formats it.
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
    namespace export firstLine lastLine lines countLines firstKernelLine oops \
        smokeDetail snap delta get field positive trafficFailures netemSent \
        dropRate netemCheck netemLimitOk netemDetail oopsCount shape
    namespace ensemble create

    # Kernel messages that fail the dmesg and serial-log phases.
    variable oopsRe {BUG:|Oops|WARNING:|KASAN|UBSAN|general protection fault|list_add corruption}
}

# ---- Text ------------------------------------------------------------------------

# homa::lc::parse::firstLine --
#
#	Returns the first line of text.
#
# Arguments:
#	text	any text.
#
# Results:
#	The first line, or an empty string if text is empty.
#
# Side effects:
#	None.

proc ::homa::lc::parse::firstLine {text} {
    return [lindex [split $text \n] 0]
}

# homa::lc::parse::lastLine --
#
#	Returns the last non-empty line of text.
#
# Arguments:
#	text	any text.
#
# Results:
#	The last non-empty line, or an empty string if there is none.
#
# Side effects:
#	None.

proc ::homa::lc::parse::lastLine {text} {
    return [lindex [lsearch -all -inline -not -exact [split $text \n] {}] end]
}

# homa::lc::parse::lines --
#
#	Splits text into its lines. Unlike split alone, trailing newlines do not
#	start more (empty) lines.
#
# Arguments:
#	text	any text.
#
# Results:
#	A list of the lines.
#
# Side effects:
#	None.

proc ::homa::lc::parse::lines {text} {
    return [split [string trimright $text \n] \n]
}

# homa::lc::parse::countLines --
#
#	Counts the lines of text that match a regular expression.
#
# Arguments:
#	re	the regular expression.
#	text	the text to search.
#
# Results:
#	How many lines of text match re.
#
# Side effects:
#	None.

proc ::homa::lc::parse::countLines {re text} {
    return [llength [lsearch -all -regexp [split $text \n] $re]]
}

# ---- Guest output --------------------------------------------------------------

# homa::lc::parse::firstKernelLine --
#
#	Finds the first kernel message in a serial log.
#
# Arguments:
#	text	the serial log.
#
# Results:
#	The message's timestamp, e.g. "[    2.179107]", or an empty string if
#	the kernel has printed nothing yet.
#
# Side effects:
#	None.

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
#
# Results:
#	A list of the matching lines, in order.
#
# Side effects:
#	None.

proc ::homa::lc::parse::oops {text {also {}}} {
    variable oopsRe
    set re [expr {$also eq "" ? $oopsRe : "$oopsRe|$also"}]
    return [lsearch -all -inline -regexp [split $text \n] $re]
}

# homa::lc::parse::oopsCount --
#
#	Counts the lines of text that report a kernel bug or warning.
#
# Arguments:
#	text	dmesg or serial console output.
#
# Results:
#	How many lines of text report a kernel bug or warning.
#
# Side effects:
#	None.

proc ::homa::lc::parse::oopsCount {text} {
    return [llength [oops $text]]
}

# homa::lc::parse::smokeDetail --
#
#	Returns the detail for the smoke phase.
#
# Arguments:
#	text	homa-smoke's output.
#	rc	the console's result for the command.
#
# Results:
#	homa-smoke's last verdict, or the last step it reached when it gave
#	none.
#
# Side effects:
#	None.

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
#
# Results:
#	A dictionary of counter name -> sum, in the order of keys.
#
# Side effects:
#	None.

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
#	Computes the counters that changed between two snaps, as after - before.
#	A counter missing from either side counts as 0.
#
# Arguments:
#	before	the earlier snap (a dictionary of counters).
#	after	the later snap.
#
# Results:
#	A dictionary of each changed counter -> its difference, in before's
#	order, then any counters only in after.
#
# Side effects:
#	None.

proc ::homa::lc::parse::delta {before after} {
    # In the first snap's order, then any new counters: a key seen twice
    # gives the same difference, and dict set keeps its first place.
    set moved [dict create]
    foreach key [concat [dict keys $before] [dict keys $after]] {
        set diff [expr {[get $after $key] - [get $before $key]}]
        if {$diff != 0} {
            dict set moved $key $diff
        }
    }
    return $moved
}

# homa::lc::parse::get --
#
#	Looks up one counter.
#
# Arguments:
#	counters	a dictionary of counters.
#	key	the counter's name.
#
# Results:
#	Counter key from counters, or 0 if it is missing.
#
# Side effects:
#	None.

proc ::homa::lc::parse::get {counters key} {
    if {[dict exists $counters $key]} {
        return [dict get $counters $key]
    }
    return 0
}

# ---- cp_node -----------------------------------------------------------------------

# homa::lc::parse::field --
#
#	Finds the word after word in a cp_node stats line (e.g. "clients:" for
#	Kops/s, "P50", "P99").
#
# Arguments:
#	line	the stats line.
#	word	the word before the value.
#	missing	what to return if there is none; "-" by default.
#
# Results:
#	The word after word, or missing if there is none.
#
# Side effects:
#	None.

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
#	Tells whether value is a number above zero.
#
# Arguments:
#	value	any string.
#
# Results:
#	1 if value is a number above zero, 0 otherwise (including "-").
#
# Side effects:
#	None.

proc ::homa::lc::parse::positive {value} {
    return [expr {[string is double -strict $value] && $value > 0}]
}

# homa::lc::parse::trafficFailures --
#
#	Judges one traffic run: "echo" fails unless every echo RPC completed,
#	"homa" or "tcp" unless that cp_node run timed any RPC (a P99 above 0; at
#	5 % loss TCP manages so few RPCs that its Kops/s rounds to 0).
#
# Arguments:
#	want	how many echo RPCs demo_client1 sends (constants.echoRpcs).
#	echoes	how many echo responses arrived.
#	homa	cp_node's last stats line over Homa.
#	tcp	cp_node's last stats line over TCP.
#
# Results:
#	A list of what failed: any of echo, homa and tcp, in that order. An
#	error if want is not an integer.
#
# Side effects:
#	None.

proc ::homa::lc::parse::trafficFailures {want echoes homa tcp} {
    if {![string is entier -strict $want]} {
        return -code error "bad echo count \"$want\""
    }
    set failed {}
    if {![string is entier -strict $echoes] || $echoes != $want} {
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
#	Reads the netem qdisc's counters from "tc -s qdisc show" output.
#
# Arguments:
#	text	"tc -s qdisc show" output.
#
# Results:
#	{packets drops} from the netem qdisc, or an empty list if there is no
#	netem qdisc with counters.
#
# Side effects:
#	None.

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
#
# Side effects:
#	None.

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

# homa::lc::parse::netemCheck --
#
#	Checks one node's netem drops (see dropRate) from its "tc -s qdisc
#	show" output. With no netem counters there is nothing to judge: the
#	check passes, and the report shows the drops as unknown.
#
# Arguments:
#	node	the node's name, for the report.
#	text	its "tc -s qdisc show dev eth1" output.
#	loss	the configured loss, in percent.
#
# Results:
#	A dictionary: ok (1 or 0) and report, e.g. "node1 4559/100969
#	(4.52%)" or "node1 ?/0 (0.00%)".
#
# Side effects:
#	None.

proc ::homa::lc::parse::netemCheck {node text loss} {
    set sent [netemSent $text]
    if {[llength $sent]} {
        lassign $sent packets drops
        set shown $drops
    } else {
        lassign {0 0 ?} packets drops shown
    }
    set measured [dropRate $packets $drops $loss]
    return [dict create ok [dict get $measured ok] report [format "%s %s/%s (%s%%)" \
        $node $shown [expr {$packets + $drops}] [dict get $measured rate]]]
}

# homa::lc::parse::netemLimitOk --
#
#	Checks that "tc qdisc show" output has a netem qdisc with exactly the
#	given limit.
#
# Arguments:
#	text	"tc qdisc show" output.
#	limit	the expected limit, in packets.
#
# Results:
#	1 if it does, 0 otherwise. An error if limit is not an integer.
#
# Side effects:
#	None.

proc ::homa::lc::parse::netemLimitOk {text limit} {
    if {![string is entier -strict $limit]} {
        return -code error "not a count: \"$limit\""
    }
    return [regexp -line -- "^qdisc netem .*limit ${limit}( |\$)" $text]
}

# homa::lc::parse::netemDetail --
#
#	Reads the netem qdisc's settings from "tc qdisc show" output.
#
# Arguments:
#	text	"tc qdisc show" output.
#
# Results:
#	The settings, without tc's "qdisc netem <handle>: root refcnt <n>"
#	prefix, or an empty string if there is no netem qdisc.
#
# Side effects:
#	None.

proc ::homa::lc::parse::netemDetail {text} {
    set re {^qdisc netem [0-9a-f]*: root refcnt [0-9]* ([^\n]*)}
    if {[regexp -line -- $re $text -> settings]} {
        return $settings
    }
    return {}
}

# ---- A driver's output ----------------------------------------------------------

# homa::lc::parse::shape --
#
#	Reduces a driver's output (a <test>.out file of homa-vm-matrix) to the
#	lines two good runs share, for homa-vm-compare: each phase's id, name
#	and verdict, the HOMA_* lines with their numbers masked, and the
#	VERDICT lines. Times, details, counters and the summary table vary
#	from run to run and are dropped.
#
# Arguments:
#	text	the output.
#
# Results:
#	A list of lines: "phase <id> <name>: <verdict>", "HOMA_..." with each
#	number (decimals too) replaced by N, and "VERDICT: ..." as it is.
#
# Side effects:
#	None.

proc ::homa::lc::parse::shape {text} {
    set lines {}
    foreach line [split $text \n] {
        if {[regexp {^\s*phase (\S+) (.*?): (PASS|FAIL|SKIP) \(\d+ ms\)} $line -> id name result]} {
            lappend lines "phase $id $name: $result"
        } elseif {[regexp {^VERDICT: } $line]} {
            lappend lines $line
        } elseif {![string match |* $line] && [regexp {HOMA_[A-Z0-9_]+.*} $line homa]} {
            lappend lines [regsub -all {\d+(?:\.\d+)?} $homa N]
        }
    }
    return $lines
}

package provide homa::lc::parse 1.0
