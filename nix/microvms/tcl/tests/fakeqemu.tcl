# fakeqemu.tcl --
#
#	Stands in for a guest's microvm-run in node.test: writes serial.log in
#	the current directory, as QEMU does, and serves a bash shell on the
#	virtio console port, as the guest's hvc0 autologin does.
#
#	    tclsh fakeqemu.tcl port mode bin
#
#	port	the virtio console port to listen on.
#	mode	ok, oops (the kernel logs a BUG, in serial.log and dmesg),
#		silent (listens, but no shell ever answers) or deaf (never
#		listens).
#	bin	put first on the shell's PATH: the test's poweroff and dmesg.
#
#	The shell's poweroff ends this process, which is how QEMU exits.

lassign $argv port mode bin

set serial {[    0.000000] Linux version 0.0-fake}
if {$mode eq "oops"} {
    append serial "\n\[    1.000000\] BUG: kernel NULL pointer dereference"
    append serial "\n\[    1.000001\] RIP: 0010:homa_fake+0x10/0x20"
}
set chan [open serial.log w]
puts $chan $serial
close $chan
puts "fake qemu: $mode on $port"
flush stdout

set env(PATH) $bin:$env(PATH)
set env(FAKE_QEMU_PID) [pid]
set env(FAKE_MODE) $mode

# serve --
#
#	Joins a console connection to a new bash (or, when silent, to
#	nothing), as the guest's autologin shell on hvc0.

proc serve {sock addr port} {
    global mode
    chan configure $sock -blocking 0 -buffering none -translation binary
    if {$mode eq "silent"} {
        chan event $sock readable [list drop $sock]
        return
    }
    set shell [open |[list bash --norc --noprofile 2>@1] r+]
    chan configure $shell -blocking 0 -buffering none -translation binary
    chan event $shell readable [list relay $shell $sock]
    chan event $sock readable [list relay $sock $shell]
}

# relay --
#
#	Copies what is ready from one channel to the other. At end of file
#	the session is over (a probe that connected and closed, or a shell
#	that exited) and both are closed; like QEMU, the fake keeps serving.

proc relay {from to} {
    puts -nonewline $to [read $from]
    if {[eof $from]} {
        catch {close $from}
        catch {close $to}
    }
}

# drop --
#
#	Reads and discards what a silent guest is sent.

proc drop {sock} {
    read $sock
    if {[eof $sock]} {
        close $sock
    }
}

if {$mode ne "deaf"} {
    socket -server serve -myaddr 127.0.0.1 $port
}
vwait forever
