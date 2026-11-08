# helpers.tcl --
#
#	Shared by every test file: loads tcltest and the package under test, and
#	defines testTable, which turns a table of cases into tcltest tests.

# Every test file sources this, and all.tcl runs them in one interpreter.
if {[package provide homa::lc::testhelpers] ne ""} {
    return
}
package provide homa::lc::testhelpers 1.0

package require tcltest 2

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require homa::lc::parse
namespace import ::homa::lc::parse

# testTable --
#
#	Runs one tcltest test per row of a table. Each row is a list
#
#	    {description category input outcome expected}
#
#	description	what the row checks, used as the test's description.
#	category	positive, negative, boundary or corner.
#	input		a single value, passed to the body as $input.
#	outcome		ok when the body must return expected, error when it
#			must raise an error whose message is expected, errorGlob
#			when the message must match expected as a glob pattern
#			(for messages that differ between Tcl versions).
#	expected	the result, error message or pattern.
#
# Arguments:
#	prefix		test name prefix; rows are numbered prefix-1, prefix-2, ...
#	cases		the table.
#	body		script run for each row, with $input set to the row's
#			input. Its result is compared with expected.
#
# Results:
#	None. Fails the run with an error if a row is malformed.

proc testTable {prefix cases body} {
    set categories {positive negative boundary corner}
    set outcomes {ok {ok exact} error {error exact} errorGlob {error glob}}
    set n 0
    foreach row $cases {
        incr n
        if {[llength $row] != 5} {
            return -code error "$prefix-$n: row has [llength $row] fields, want 5"
        }
        lassign $row description category value outcome expected
        if {$category ni $categories} {
            return -code error "$prefix-$n: unknown category \"$category\""
        }
        if {![dict exists $outcomes $outcome]} {
            return -code error "$prefix-$n: unknown outcome \"$outcome\""
        }
        lassign [dict get $outcomes $outcome] codes match
        tcltest::test $prefix-$n "$category: $description" \
            -body [list apply [list input $body] $value] \
            -returnCodes $codes -match $match -result $expected
    }
}

# Capture --
#
#	A channel transform that keeps what is written to a channel instead of
#	passing it on, so tests can check what Table prints.

oo::class create Capture {
    variable text

    constructor {} {
        set text ""
    }

    method initialize {chan mode} {
        return {initialize finalize write}
    }

    method finalize {chan} {
        my destroy
    }

    method write {chan bytes} {
        append text $bytes
        return ""
    }

    method text {} {
        return $text
    }
}

# quietly --
#
#	Runs script in the caller's scope with stdout captured. The transform
#	sees bytes after end-of-line translation, so lf is set meanwhile (a
#	build sandbox's stdout may translate to crlf).
#
# Results:
#	A list: the script's result, and what it printed.

##nagelfar syntax quietly c
proc quietly {script} {
    set translation [chan configure stdout -translation]
    chan configure stdout -translation lf
    set capture [Capture new]
    chan push stdout $capture
    try {
        set result [uplevel 1 $script]
        flush stdout
        return [list $result [$capture text]]
    } finally {
        chan pop stdout
        chan configure stdout -translation $translation
    }
}
