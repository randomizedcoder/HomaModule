# lintdb.tcl --
#
#	Prints a nagelfar syntax database for this package, so nagelfar can
#	check code that uses it, including the scripts passed to Table phase:
#
#	    tclsh lintdb.tcl > homa.db
#	    nagelfar -s syntaxdb86.tcl -s homa.db ...
#
#	The ensemble and class entries come from the loaded code (ensemble
#	maps, info args, info class definition), so they follow it. Only
#	methods that take a script, and the Expect and tcllib commands, are
#	written out here.

set auto_path [linsert $auto_path 0 [file dirname [file dirname [file normalize [info script]]]]]
package require homa::lc

# Commands from Expect and tcllib, and the variables Expect sets.
set fixed {
    log_user x
    match_max x*
    spawn x*
    exp_send x*
    expect x*
    exp_continue x?
    json::json2dict x
}

# Arguments that are scripts, run in the caller's scope: methods as
# "Class method", procedures by their name in homa::lc.
set scripts {
    {Table phase} {x x c}
    withEnv {x x c}
}

# tokens --
#
#	Returns nagelfar's syntax tokens for an argument list, as from info
#	args or a method definition: x for each required argument, x? for each
#	one with a default, x* for args.

proc tokens {arguments} {
    if {![llength $arguments]} {
        return 0
    }
    return [lmap arg $arguments {
        if {[lindex $arg 0] eq "args"} {
            string cat x*
        } elseif {[llength $arg] > 1} {
            string cat x?
        } else {
            string cat x
        }
    }]
}

# procArgs --
#
#	Returns a procedure's argument list as proc takes it: each argument,
#	or {argument default}.

proc procArgs {cmd} {
    return [lmap arg [info args $cmd] {
        if {[info default $cmd $arg value]} {list $arg $value} else {set arg}
    }]
}

# syntax --
#
#	Prints one ##nagelfar directive. A space in the command name (an
#	object type and its method) is escaped; the rest are plain words.

proc syntax {directive name args} {
    puts "##nagelfar $directive [string map {" " "\\ "} $name] [join $args]"
}

dict for {name spec} $fixed {
    syntax syntax $name {*}$spec
}
puts "##nagelfar implicitvarcmd {spawn *} spawn_id"

# The parse ensemble, under its full name and as imported.
set map [namespace ensemble configure ::homa::lc::parse -map]
if {![llength $map]} {
    foreach cmd [info commands ::homa::lc::parse::*] {
        dict set map [namespace tail $cmd] $cmd
    }
}
foreach ensemble {homa::lc::parse parse} {
    syntax syntax $ensemble s x*
    syntax subcmd $ensemble {*}[lsort [dict keys $map]]
    foreach sub [lsort [dict keys $map]] {
        syntax syntax "$ensemble $sub" {*}[tokens [procArgs [dict get $map $sub]]]
    }
}

# The package's own procedures, under their full names and as found from
# the classes' methods (namespace path).
foreach cmd [lsort [info procs ::homa::lc::*]] {
    if {[dict exists $scripts [namespace tail $cmd]]} {
        set spec [dict get $scripts [namespace tail $cmd]]
    } else {
        set spec [tokens [procArgs $cmd]]
    }
    syntax syntax [string trimleft $cmd :] {*}$spec
    syntax syntax [namespace tail $cmd] {*}$spec
}

# The classes: each object is a command whose subcommands are its public
# methods, and Class new returns one.
foreach class {Table Node Batch Console} {
    set type _obj,$class
    set methods [lsort [concat [info class methods homa::lc::$class] destroy]]
    syntax syntax $type s x*
    syntax subcmd $type {*}$methods
    foreach method $methods {
        if {[dict exists $scripts "$class $method"]} {
            set spec [dict get $scripts "$class $method"]
        } elseif {$method eq "destroy"} {
            set spec 0
        } else {
            set spec [tokens [lindex [info class definition homa::lc::$class $method] 0]]
        }
        syntax syntax "$type $method" {*}$spec
    }
    set ctor [lindex [info class constructor homa::lc::$class] 0]
    syntax syntax "homa::lc::$class new" {*}[tokens $ctor]
    syntax return "homa::lc::$class new" $type
}
