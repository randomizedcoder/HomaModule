# console.tcl --
#
#	homa::lc::Console runs shell commands over a guest's console: a TCP
#	connection to QEMU's virtio console (hvc0), where the guest runs a root
#	shell. Expect does the reading; this class adds the end-marker protocol
#	(protocol.tcl), so each command's exit status comes back with its output.

package require Tcl 8.6-
package require Expect
package require homa::lc::protocol

namespace eval ::homa::lc {
    namespace export Console
}

# Expect copies everything it reads to stdout unless told not to; console
# output goes to the phase logs instead.
log_user 0

# homa::lc::Console --
#
#	One guest console.
#
#	    set console [homa::lc::Console new [socket 127.0.0.1 $port]]
#	    set result [$console run "uname -r" 30]
#	    dict get $result rc	;# the command's exit status, 124, or 125
#	    dict get $result out	;# its output, without the final newline
#
#	A command that times out leaves its output and end marker to arrive
#	later; the numbered markers let the next command skip them. Once the
#	connection closes, every command returns 125 at once.

oo::class create ::homa::lc::Console {
    # spawnId	Expect's id for the connection, or "" once it has closed.
    # lastId	the number of the last command sent.
    variable spawnId lastId

    # constructor --
    #
    #	Takes over chan, a connected socket (or any readable and writable
    #	channel); it is closed when the console closes.
    #
    # Arguments:
    #	chan		the channel.
    #	matchMax	bytes Expect buffers before handing a partial line over
    #			(see run). Tests lower it to exercise long lines.

    constructor {chan {matchMax 65536}} {
        # Methods run in the object's namespace; find protocol.
        namespace path ::homa::lc
        set lastId 0
        spawn -noecho -open $chan
        set spawnId $spawn_id
        match_max -i $spawnId $matchMax
    }

    destructor {
        my Close
    }

    # alive --
    #
    #	Returns 1 while the connection is open.

    method alive {} {
        return [expr {$spawnId ne ""}]
    }

    # send --
    #
    #	Writes one line to the guest without waiting for anything, e.g.
    #	"poweroff". Returns 1 if it was written, 0 if the console has closed.

    method send {line} {
        if {$spawnId eq ""} {
            return 0
        }
        try {
            exp_send -i $spawnId -- "$line\n"
        } on error {} {
            my Close
            return 0
        }
        return 1
    }

    # run --
    #
    #	Runs one shell command and waits for its end marker.
    #
    # Arguments:
    #	cmd	the command, as the guest's shell will read it.
    #	timeout	seconds to wait for the whole command.
    #
    # Results:
    #	A dictionary:
    #	rc	the command's exit status; 124 if it did not finish in time;
    #		125 if the console closed (the guest powered off or crashed).
    #	out	what the command printed, one line per line, with carriage
    #		returns and every end marker removed.

    method run {cmd timeout} {
        set id [incr lastId]
        if {![my send [protocol wrap $cmd $id]]} {
            return [dict create rc 125 out {}]
        }
        set status 124
        set lines {}
        set partial {}
        # One line per match, so the buffer never holds more than a line
        # (and Expect's match_max limit applies to single lines). A longer
        # line fills the buffer; full_buffer keeps what it has so far. The
        # whole match is used, not a subexpression: Expect sets an empty
        # subexpression to the rest of the buffer.
        expect -i $spawnId -timeout $timeout -re {[^\n]*\n} {
            set line $partial[string range $expect_out(0,string) 0 end-1]
            set partial {}
            lassign [protocol line $id $line] keep text done rc
            if {$keep} {
                lappend lines $text
            }
            if {!$done} {
                exp_continue -continue_timer
            }
            set status $rc
        } full_buffer {
            append partial $expect_out(buffer)
            exp_continue -continue_timer
        } eof {
            my Close
            set status 125
        }
        return [dict create rc $status out [join $lines \n]]
    }

    # Close --
    #
    #	Closes the connection (and the channel Expect took over), once.

    method Close {} {
        if {$spawnId ne ""} {
            catch {close -i $spawnId}
            set spawnId {}
        }
    }
}

package provide homa::lc::console 1.0
