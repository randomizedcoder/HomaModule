# protocol.tcl --
#
#	The end-marker protocol homa::lc::Console speaks to a guest's shell.
#	Each command sent is followed by an echo of a numbered end marker that
#	carries the command's exit status:
#
#	    uname -r; echo "HOMA_LC_""END 7 rc=$?"
#
#	The quotes split the marker in the command itself, so a shell that
#	echoes its input never prints a line that matches. A command that timed
#	out prints its output and marker later, under an older number; the
#	next command keeps that output but does not stop at its marker.
#
#	Pure, like parse.tcl: tests/protocol.test covers it with tables, on
#	Tcl 8.6 and 9. Only console.tcl uses it.

package require Tcl 8.6-

namespace eval ::homa::lc::protocol {
    namespace export wrap line
    namespace ensemble create

    # Any end marker, ours or a stale one; the first subexpression is its
    # command number, the second its exit status.
    variable markerRe {HOMA_LC_END (\d+) rc=(\d+)}
}

# homa::lc::protocol::wrap --
#
#	Returns the line to send to the shell for one command.
#
# Arguments:
#	cmd	the shell command, on one line: the shell would print a
#		continuation prompt into the output for each further line.
#	id	the command's number, a positive integer.
#
# Results:
#	The command followed by its end marker's echo.
#
# Side effects:
#	None.

proc ::homa::lc::protocol::wrap {cmd id} {
    checkId $id
    if {[string trim $cmd] eq ""} {
        return -code error "empty command"
    }
    if {[string first \n $cmd] >= 0} {
        return -code error "command has more than one line"
    }
    return "$cmd; echo \"HOMA_LC_\"\"END $id rc=\$?\""
}

# homa::lc::protocol::line --
#
#	Reads one line the shell printed while command id was running.
#
# Arguments:
#	id	the running command's number.
#	line	the line, without its newline; a tty's carriage return is
#		allowed.
#
# Results:
#	A list {keep text done rc}:
#	keep	1 if text is output to keep. A line that held only an end
#		marker is dropped; any other line is kept, blank or not.
#	text	the line without the carriage return or any end marker,
#		leaving what came before it on the line ("printf abc" prints no
#		newline before the marker).
#	done	1 if the line carries command id's marker.
#	rc	the command's exit status if done, else "".
#
# Side effects:
#	None.

proc ::homa::lc::protocol::line {id line} {
    variable markerRe
    checkId $id
    set line [string trimright $line \r]
    set rc {}
    foreach {- markerId status} [regexp -all -inline -- $markerRe $line] {
        if {$markerId eq $id} {
            set rc $status
        }
    }
    set text [regsub -all -- $markerRe $line {}]
    set keep [expr {$text ne "" || $text eq $line}]
    return [list $keep $text [expr {$rc ne ""}] $rc]
}

# homa::lc::protocol::checkId --
#
#	Raises an error unless id is a positive integer.
#
# Results:
#	None.
#
# Side effects:
#	None.

proc ::homa::lc::protocol::checkId {id} {
    if {![string is entier -strict $id] || $id < 1} {
        return -code error "bad command id \"$id\""
    }
}

package provide homa::lc::protocol 1.0
