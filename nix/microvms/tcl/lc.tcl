# lc.tcl --
#
#	The lifecycle drivers' building blocks:
#
#	homa::lc::Table	the phase table: times and records each phase, prints
#			its line, and writes summary.md with the VERDICT.
#	homa::lc::Node	one guest: its QEMU process and consoles, and the
#			phases every lifecycle test runs on each guest (start,
#			serial, virtio, dmesg, shutdown, exit, serial-log).
#	homa::lc::Batch	runs whole test commands in parallel, each in its own
#			directory (homa-vm-matrix).
#
#	A failed phase does not stop a run, but phases that need a guest's
#	shell are SKIPped once it is gone.

package require Tcl 8.6-
package require homa::lc::parse
package require homa::lc::report
package require homa::lc::console

namespace eval ::homa::lc {
    namespace export Table Node Batch logdir waitFor slurp spit utf8 withEnv
}

# homa::lc::waitFor --
#
#	Waits until condition is true or ms milliseconds have passed, checking
#	it every interval milliseconds and handling the events that came in
#	meanwhile (QEMU's output, for one), which a plain "after" would not.
#	There is no flag to share: a wait started by an event handler during
#	another one just runs to its own deadline, and the outer one then
#	goes on to its own.
#
# Arguments:
#	ms		how long to wait, at least 0.
#	interval	how often to check, at least 1.
#	condition	an expression, evaluated in the caller's scope, as
#			while does. It is checked once more at the deadline.
#
# Results:
#	1 if the condition became true, 0 if the time ran out.

proc ::homa::lc::waitFor {ms interval condition} {
    if {![string is entier -strict $ms] || $ms < 0} {
        return -code error "bad wait \"$ms\""
    }
    if {![string is entier -strict $interval] || $interval < 1} {
        return -code error "bad interval \"$interval\""
    }
    set deadline [expr {[clock milliseconds] + $ms}]
    while {![uplevel 1 [list expr $condition]]} {
        set left [expr {$deadline - [clock milliseconds]}]
        if {$left <= 0} {
            return 0
        }
        after [expr {min($interval, $left)}]
        update
    }
    return 1
}

# homa::lc::logdir --
#
#	Returns the run's log directory: $HOMA_VM_LOGDIR, created if need be,
#	or a new temporary directory.

proc ::homa::lc::logdir {} {
    global env
    if {[info exists env(HOMA_VM_LOGDIR)] && $env(HOMA_VM_LOGDIR) ne ""} {
        file mkdir $env(HOMA_VM_LOGDIR)
        return [file normalize $env(HOMA_VM_LOGDIR)]
    }
    return [exec mktemp -d]
}

# homa::lc::slurp --
#
#	Returns a file's contents, read as UTF-8, or an empty string if it does
#	not exist (yet). Bytes that are not UTF-8 (a serial log can hold line
#	noise) are kept as single characters rather than raising an error.

proc ::homa::lc::slurp {path} {
    try {
        set chan [open $path r]
    } trap {POSIX ENOENT} {} {
        return {}
    }
    try {
        utf8 $chan
        return [read $chan]
    } finally {
        close $chan
    }
}

# homa::lc::spit --
#
#	Writes text, as UTF-8, plus a final newline unless it is empty, to a
#	file.
#
# Arguments:
#	path	the file.
#	text	what to write.
#	access	w to replace the file, a to append to it.

proc ::homa::lc::spit {path text {access w}} {
    set chan [open $path $access]
    try {
        utf8 $chan
        puts -nonewline $chan [expr {$text eq "" ? "" : "$text\n"}]
    } finally {
        close $chan
    }
}

# homa::lc::utf8 --
#
#	Makes a channel read and write UTF-8 whatever the locale, and, on
#	Tcl 9, replace bad bytes rather than fail on them (8.6 always does).

proc ::homa::lc::utf8 {chan} {
    chan configure $chan -encoding utf-8
    if {[package vsatisfies [package provide Tcl] 9-]} {
        chan configure $chan -profile replace
    }
}

# homa::lc::withEnv --
#
#	Runs script in the caller's scope with env(name) set to value, then
#	puts env(name) back as it was, set or unset, even if script fails.
#	Tcl 8.6's "open |" has no option for a child's environment, so it is
#	set around the open.
#
# Results:
#	The script's result.

proc ::homa::lc::withEnv {name value script} {
    global env
    set had [info exists env($name)]
    if {$had} {
        set old $env($name)
    }
    set env($name) $value
    try {
        return [uplevel 1 $script]
    } finally {
        if {$had} {
            set env($name) $old
        } else {
            unset -nocomplain env($name)
        }
    }
}

# homa::lc::Batch --
#
#	Runs test commands in parallel, at most limit at a time, each in its
#	own directory under logdir with HOMA_VM_LOGDIR set to it, and its
#	output in logdir/<name>.out.
#
#	    set batch [homa::lc::Batch new $logdir 4]
#	    set results [$batch run {{name a exe /bin/a} {name b exe /bin/b}}]
#	    dict get $results a	;# {rc secs}
#
#	rc is the command's exit status, or the signal's name (e.g. SIGKILL)
#	if one ended it.

oo::class create ::homa::lc::Batch {
    # logdir	where each test's directory and .out file go.
    # limit	how many tests may run at once.
    # waiting	the tests not started yet.
    # running	how many are running.
    # results	test name -> {rc secs}, as each finishes.
    variable logdir limit waiting running results

    constructor {dir jobs} {
        # Methods run in the object's namespace; find withEnv.
        namespace path ::homa::lc
        if {![string is entier -strict $jobs] || $jobs < 1} {
            return -code error "bad job limit \"$jobs\""
        }
        set logdir $dir
        set limit $jobs
        lassign {{} 0 {}} waiting running results
    }

    # run --
    #
    #	Runs tests, a list of dictionaries each with a name and an exe (a
    #	command without arguments), and waits for all of them.
    #
    # Results:
    #	A dictionary: each test's name -> {rc secs}.

    method run {tests} {
        set names [lmap test $tests {dict get $test name}]
        if {[llength [lsort -unique $names]] != [llength $names]} {
            return -code error "test names are not unique: $names"
        }
        set waiting $tests
        set results [dict create]
        my Fill
        while {[dict size $results] < [llength $tests]} {
            vwait [my varname results]
        }
        return $results
    }

    # Fill --
    #
    #	Starts waiting tests, up to the limit.

    method Fill {} {
        while {[llength $waiting] && $running < $limit} {
            set waiting [lassign $waiting test]
            my Start [dict get $test name] [dict get $test exe]
        }
    }

    # Start --
    #
    #	Starts one test. microvm.nix puts the QMP socket (<hostname>.sock)
    #	in the current directory, and every pair's server is node0: hence a
    #	directory each.

    method Start {name exe} {
        set dir [file join $logdir $name]
        file mkdir $dir
        set out [open [file join $logdir $name.out] w]
        set here [pwd]
        cd $dir
        try {
            set chan [withEnv HOMA_VM_LOGDIR $dir {open |[list $exe < /dev/null 2>@1] r}]
        } on error {message} {
            close $out
            dict set results $name [list "error: $message" 0]
            return
        } finally {
            cd $here
        }
        chan configure $chan -blocking 0 -translation binary
        chan configure $out -translation binary
        chan event $chan readable [namespace code [list my Copy $name $chan $out [clock seconds]]]
        incr running
    }

    # Copy --
    #
    #	Copies a test's output to its .out file. At eof, records its exit
    #	status and time, and starts the next waiting test.

    method Copy {name chan out started} {
        puts -nonewline $out [read $chan]
        if {![eof $chan]} {
            return
        }
        close $out
        chan configure $chan -blocking 1
        set rc 0
        try {
            close $chan
        } trap CHILDSTATUS {- options} {
            set rc [lindex [dict get $options -errorcode] 2]
        } trap CHILDKILLED {- options} {
            set rc [lindex [dict get $options -errorcode] 2]
        }
        puts "  done: $name (exit $rc)"
        incr running -1
        dict set results $name [list $rc [expr {[clock seconds] - $started}]]
        my Fill
    }
}

# homa::lc::Table --
#
#	The phase table of one run.
#
#	    set table [homa::lc::Table new]
#	    $table phase 3 smoke {
#	        ...
#	        list $rc $detail
#	    }
#	    exit [$table verdict]

oo::class create ::homa::lc::Table {
    # rows	summary.md's rows, one per phase.
    # failed	how many phases failed.
    variable rows failed

    constructor {} {
        # Methods run in the object's namespace; find report and spit.
        namespace path ::homa::lc
        set rows {}
        set failed 0
    }

    # record --
    #
    #	Records one phase and prints its line.
    #
    # Arguments:
    #	id	the phase's number, e.g. 2b or 8.3.
    #	name	its name.
    #	rc	0 for PASS, skip for SKIP, anything else for FAIL.
    #	start	when it started, from clock milliseconds.
    #	detail	a short note for the table.

    method record {id name rc start {detail {}}} {
        set result [report verdict $rc]
        if {$result eq "FAIL"} {
            incr failed
        }
        set ms [expr {[clock milliseconds] - $start}]
        lappend rows [report tableRow $id $name $result $ms $detail]
        puts [report phaseLine $id $name $result $ms $detail]
    }

    # skip --
    #
    #	Records a phase that could not run.

    method skip {id name detail} {
        my record $id $name skip [clock milliseconds] $detail
    }

    # phase --
    #
    #	Times script, run in the caller's scope, and records its result: a
    #	list {rc detail}, either the script's value or what it returns.
    #	Anything else fails the phase rather than the run: an error (its
    #	stack goes to phase-errors.log), a break or continue, or a result
    #	without a valid rc.
    #
    # Results:
    #	The phase's rc.

    method phase {id name script} {
        set start [clock milliseconds]
        try {
            uplevel 1 $script
        } on ok {result} - on return {result} {
            set outcome [my Outcome $result]
        } on break {} {
            set outcome {1 {error: break in phase script}}
        } on continue {} {
            set outcome {1 {error: continue in phase script}}
        } on error {message options} {
            spit phase-errors.log "phase $id $name: $message\n[dict get $options -errorinfo]" a
            set outcome [list 1 "error: $message"]
        }
        lassign $outcome rc detail
        my record $id $name $rc $start $detail
        return $rc
    }

    # Outcome --
    #
    #	Returns a phase script's result as {rc detail}, or {1 "error: ..."}
    #	if it is not a list with a valid rc.

    method Outcome {result} {
        try {
            lassign $result rc detail
            report verdict $rc
            return [list $rc $detail]
        } on error {message} {
            return [list 1 "error: $message"]
        }
    }

    # verdict --
    #
    #	Writes summary.md (in the current directory), prints it and the
    #	VERDICT line, and returns the exit code for the run.

    method verdict {} {
        set table [join [list \
            "| Phase | Name | Result | Time (ms) | Detail |" \
            "|---|---|---|---|---|" {*}$rows] \n]
        spit summary.md $table
        puts "\n$table\n"
        if {$failed} {
            puts "VERDICT: FAIL ($failed phases)"
            return 1
        }
        puts "VERDICT: PASS"
        return 0
    }
}

# homa::lc::Node --
#
#	One guest, built with consolePorts (mkVm.nix): ttyS0 on one host TCP
#	port, logged by QEMU to serial.log from the first byte, and a root
#	shell on hvc0 (the virtio console) on another.
#
#	    set node [homa::lc::Node new $table node0 $vm $timeouts " node0"]
#	    $node start 1
#	    ...
#	    $node phase 4 insmod {
#	        set result [$node run insmod.log 30 {insmod "$HOMA_KO"}]
#	        list [dict get $result rc] ""
#	    }
#
#	dir is the guest's log directory, which is also QEMU's working
#	directory. vm is a dictionary: runner (its microvm runner), serial and
#	virtio (the console ports). timeouts gives seconds per phase: start,
#	serial, virtio, command and exit.

oo::class create ::homa::lc::Node {
    # table		the run's homa::lc::Table.
    # suffix		appended to this node's phase names, e.g. " node0".
    # dir, timeouts	from the constructor.
    # runner, serialPort, virtioPort	from vm.
    # qemu		the QEMU pipeline, "" once it has exited.
    # qemuLog		the channel its output is copied to.
    # console		the hvc0 homa::lc::Console, "" until connected.
    # shell		1 once the shell on hvc0 has answered.
    # poweroffSent	1 once "poweroff" has been sent.
    variable table suffix dir runner serialPort virtioPort timeouts \
        qemu qemuLog console shell poweroffSent

    constructor {phaseTable logDir vm phaseTimeouts {nameSuffix {}}} {
        namespace path ::homa::lc
        set table $phaseTable
        set dir $logDir
        set timeouts $phaseTimeouts
        set suffix $nameSuffix
        lassign [lmap key {runner serial virtio} {dict get $vm $key}] \
            runner serialPort virtioPort
        lassign {{} {} {} 0 0} qemu qemuLog console shell poweroffSent
    }

    # destructor --
    #
    #	Kills QEMU if it is still running, and closes the console.

    destructor {
        if {$console ne ""} {
            $console destroy
        }
        if {$qemu ne ""} {
            catch {exec kill {*}[pid $qemu]}
            my Reap
        }
    }

    # dir --
    #
    #	Returns the node's log directory.

    method dir {} {
        return $dir
    }

    # shell --
    #
    #	Returns 1 while the node's shell answers on hvc0.

    method shell {} {
        return [expr {$shell && [$console alive]}]
    }

    # need --
    #
    #	Returns 1 if the shell answers; otherwise SKIPs the phase and
    #	returns 0.

    method need {id name} {
        if {[my shell]} {
            return 1
        }
        $table skip $id $name "no shell on hvc0"
        return 0
    }

    # phase --
    #
    #	A phase that needs this node's shell: runs script as Table phase
    #	does, in the caller's scope, or SKIPs it if the shell is gone.
    #
    # Results:
    #	The phase's rc, or skip.

    method phase {id name script} {
        if {![my need $id $name]} {
            return skip
        }
        tailcall $table phase $id $name $script
    }

    # run --
    #
    #	Runs a command in the node's shell (see homa::lc::Console run) and
    #	writes its output to log, in the node's directory.
    #
    # Arguments:
    #	log	the log file's name.
    #	timeout	seconds.
    #	cmd	the command.
    #	access	w to replace the log, a to append to it.
    #
    # Results:
    #	The Console's result, {rc out}.

    method run {log timeout cmd {access w}} {
        set result [$console run $cmd $timeout]
        spit [file join $dir $log] [dict get $result out] $access
        return $result
    }

    # ---- Phases ----------------------------------------------------------------

    # start --
    #
    #	Starts QEMU in the node's directory and waits for its console ports.

    method start {id} {
        $table phase $id start$suffix {
            file mkdir $dir
            set here [pwd]
            cd $dir
            try {
                set qemu [open |[list $runner/bin/microvm-run < /dev/null 2>@1] r]
            } finally {
                cd $here
            }
            set qemuLog [open [file join $dir qemu.log] w]
            chan configure $qemu -blocking 0 -translation binary
            chan configure $qemuLog -translation binary
            chan event $qemu readable [namespace code {my Drain}]
            set qemuPid [pid $qemu]
            set listening 0
            waitFor [my Ms start] 100 {$qemu eq "" || [set listening [my Listening]]}
            list [expr {!$listening}] "qemu pid $qemuPid, consoles on $serialPort/$virtioPort"
        }
    }

    # serial --
    #
    #	Waits for the first kernel line in serial.log. NixOS boots "quiet",
    #	so that is any kernel message, not the banner.

    method serial {id} {
        $table phase $id serial$suffix {
            set first {}
            waitFor [my Ms serial] 200 {$qemu eq "" || [set first [my FirstKernelLine]] ne ""}
            list [expr {$first eq ""}] "first kernel line at $first"
        }
    }

    # virtio --
    #
    #	Connects to hvc0 and probes until the autologin shell answers. The
    #	probe also makes it a plain shell: no echo, no (coloured) prompt, no
    #	pager. Probes sent before the shell started are answered late, and
    #	the console's numbered markers skip those answers.

    method virtio {id} {
        $table phase $id virtio$suffix {
            set up {}
            if {![catch {socket 127.0.0.1 $virtioPort} chan]} {
                set console [Console new $chan]
                # Each probe waits up to 3 s for its answer.
                waitFor [my Ms virtio] 1 {
                    $qemu eq "" || ![$console alive] || [set shell [my Probe]]
                }
            }
            if {$shell} {
                set out [dict get [my run uptime.log [dict get $timeouts command] \
                    {echo $(uname -r) $(cut -d' ' -f1 /proc/uptime)}] out]
                lassign [parse lastLine $out] kernel uptime
                set up "kernel $kernel, guest uptime $uptime s"
            }
            list [expr {!$shell}] $up
        }
    }

    # dmesg --
    #
    #	Fails if the guest's dmesg reports a kernel bug or warning.

    method dmesg {id} {
        my phase $id dmesg$suffix {
            set result [my run dmesg.log [dict get $timeouts command] dmesg]
            set out [dict get $result out]
            my Report [lrange [parse oops $out] 0 4]
            set rc [expr {[parse oopsCount $out] ? 1 : [dict get $result rc]}]
            list $rc "[llength [parse lines $out]] lines"
        }
    }

    # shutdown --
    #
    #	Sends poweroff over hvc0, without waiting.

    method shutdown {id} {
        my phase $id shutdown$suffix {
            set poweroffSent [$console send poweroff]
            list [expr {!$poweroffSent}] "poweroff sent over hvc0"
        }
    }

    # waitExit --
    #
    #	Waits for QEMU to exit, which it must not do before the poweroff.

    method waitExit {id} {
        $table phase $id exit$suffix {
            waitFor [my Ms exit] 200 {$qemu eq ""}
            if {$qemu ne ""} {
                list 1 "still running after [dict get $timeouts exit] s"
            } elseif {!$poweroffSent} {
                list 1 "qemu exited before poweroff (guest crash?)"
            } else {
                list 0 "after poweroff"
            }
        }
    }

    # serialLog --
    #
    #	Fails if serial.log reports a kernel bug or warning anywhere,
    #	including after the shell has gone (late RCU callbacks: STATUS.md
    #	F8).

    method serialLog {id} {
        $table phase $id serial-log$suffix {
            set text [slurp [file join $dir serial.log]]
            my Report [lrange [parse oops $text RIP:] 0 5]
            list [expr {[parse oopsCount $text] > 0}] "[llength [parse lines $text]] lines"
        }
    }

    # ---- Internals ---------------------------------------------------------------

    # Ms --
    #
    #	Returns timeouts(key), which is in seconds, in milliseconds.

    method Ms {key} {
        return [expr {[dict get $timeouts $key] * 1000}]
    }

    # Listening --
    #
    #	Returns 1 if the virtio console port accepts a connection.

    method Listening {} {
        if {[catch {socket 127.0.0.1 $virtioPort} probe]} {
            return 0
        }
        close $probe
        return 1
    }

    # FirstKernelLine --
    #
    #	Returns the timestamp of the first kernel line in serial.log so far,
    #	or an empty string.

    method FirstKernelLine {} {
        return [parse firstKernelLine [slurp [file join $dir serial.log]]]
    }

    # Probe --
    #
    #	Sends the plain-shell settings over hvc0 and returns 1 if the shell
    #	answered them within 3 s.

    method Probe {} {
        set plain [join {
            {stty -echo} PS1= PROMPT_COMMAND= {export TERM=dumb PAGER=cat SYSTEMD_PAGER=}
        } "; "]
        return [expr {[dict get [my run virtio.log 3 $plain a] rc] == 0}]
    }

    # Report --
    #
    #	Prints lines of guest output under the phase line, indented.

    method Report {lines} {
        foreach line $lines {
            puts "    $line"
        }
    }

    # Drain --
    #
    #	Copies QEMU's output to qemu.log. At end of file QEMU has exited.

    method Drain {} {
        puts -nonewline $qemuLog [read $qemu]
        if {[eof $qemu]} {
            my Reap
        }
    }

    # Reap --
    #
    #	Reaps QEMU and closes its log.

    method Reap {} {
        chan configure $qemu -blocking 1
        catch {close $qemu}
        close $qemuLog
        set qemu {}
    }
}

package provide homa::lc 1.0
