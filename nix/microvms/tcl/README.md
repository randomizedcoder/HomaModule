# nix/microvms/tcl: the lifecycle drivers, in Tcl and Expect

The lifecycle tests boot QEMU guests and drive them from the host, phase by phase, over
each guest's consoles. This directory is the code that does the driving: a small Tcl
package, `homa::lc`, and one driver script per test. Nix (`../tcl.nix`) packages each
driver as a command and passes it its configuration as a JSON file. That way, every port,
timeout and netem setting still comes from `../constants.nix`.

| Command                         | Driver                   | Nix wrapper                |
|---------------------------------|--------------------------|----------------------------|
| `homa-lifecycle[-<series>]`      | `bin/lifecycle.tcl`      | `../lifecycle.nix`         |
| `homa-pair-lifecycle[-<series>]` | `bin/pair-lifecycle.tcl` | `../pair-lifecycle.nix`    |
| `homa-vm-matrix`                 | `bin/vm-matrix.tcl`      | `../matrix.nix`            |

```sh
nix run .#homa-lifecycle-7_3          # one guest: boot, smoke, module cycles, dmesg, poweroff
nix run .#homa-pair-lifecycle-6_12    # two guests: traffic, netem loss, Homa's qdisc
HOMA_VM_LOGDIR=/tmp/lc nix run .#homa-lifecycle   # keep the logs somewhere known
HOMA_VM_JOBS=4 nix run .#homa-vm-matrix            # every VM test, at most 4 at once
nix build .#checks.x86_64-linux.tcl-tests          # the tests and lint below
```

## Files

| File | Package | What it is |
|---|---|---|
| `parse.tcl` | `homa::lc::parse` | Pure functions, with no I/O: the console's end-marker protocol, phase lines and verdicts, and the parsing of guest output (counters, cp_node lines, netem stats, oopses). An ensemble: `parse verdict 124`. Runs on Tcl 8.6 and 9. |
| `console.tcl` | `homa::lc::console` | `Console`, a TclOO class. It runs one shell command at a time over a guest console with Expect, and returns `{rc out}`. |
| `lc.tcl` | `homa::lc` | `Table`, the phase table: it times each phase, prints its line and writes `summary.md` with the VERDICT. `Node`, one guest: its QEMU process, its consoles, and the phases every test runs on each guest. `Batch` runs whole tests as child processes, up to a job limit, through the event loop. |
| `pkgIndex.tcl` | | Tells `package require` where each package lives. |
| `bin/*.tcl` | | The drivers. Each reads its JSON config, then runs its phases. |
| `tests/` | | The tcltest suite and the lint database generator (below). |

## The console protocol

Each guest runs a root shell on hvc0, and QEMU exposes that console as a host TCP port.
`Console run` sends one command line followed by an end marker:

```
homa-smoke 2>&1; echo "HOMA_LC_""END 7 rc=$?"
```

It then reads lines until `HOMA_LC_END 7 rc=<n>` arrives. The quotes split the marker in
the command as sent, so a console that echoes the command back cannot fake the marker. A
command that times out leaves its own marker to arrive later. The marker's number tells the
next command to skip it.

`run` returns rc 124 on a timeout and 125 once the connection has closed, the same codes
`timeout(1)` uses. Expect does the buffering, so a line split across TCP reads, a CRLF, or
a line longer than Expect's buffer are all handled in one place.

## The phase table contract

Each phase prints one line, and the run ends with one VERDICT line. `homa-vm-matrix` and
humans both read these, so the format is fixed (`parse phaseLine`):

```
  phase 3 smoke: PASS (5210 ms): HOMA_SMOKE_PASS
VERDICT: FAIL (2 phases)
```

A phase script returns `{rc detail}`. An rc of 0 is a PASS, `skip` is a SKIP, and anything
else is a FAIL. If the script raises an error, or returns no valid rc, only that phase
fails, and the run goes on. Once a guest's shell is gone, the phases that need it SKIP.

## Tests

Every test is a row in a table, with a description, a category (positive, negative,
boundary or corner), its input, and the expected result or error (`testTable` in
`tests/helpers.tcl`):

```tcl
testTable combine {
    {"the first failure is kept" positive {0 1} ok 1}
    ...
} {parse combine {*}$input}
```

| File | Covers |
|---|---|
| `tests/parse.test` | every `parse` function |
| `tests/console.test` | `Console`, against a real bash behind a local socket: timeouts, eof, stale markers, CRLF, split writes, 20000-line outputs |
| `tests/table.test` | `Table`: verdicts, the phase lines, `summary.md`, errors inside phases |
| `tests/node.test` | `Node`'s phases end to end, against `tests/fakeqemu.tcl`: a fake QEMU that writes a serial log and serves bash on the console port, booting cleanly, with a kernel BUG, with a shell that never answers, never listening, or not starting at all |
| `tests/files.test` | `slurp` and `spit`: UTF-8 whatever the locale, missing and empty files, bytes that are not UTF-8, appends |
| `tests/batch.test` | `Batch`: exit codes, signals, a command that cannot start, each test's own directory, the job limit, bad limits and duplicate names |

Run them directly:

```sh
cd nix/microvms/tcl/tests
TCLLIBPATH=$(nix build --no-link --print-out-paths nixpkgs#expect)/lib \
  nix shell nixpkgs#tcl -c tclsh all.tcl                    # all of them, Tcl 8.6
nix shell nixpkgs#tcl-9_0 -c tclsh all.tcl -file parse.test # the pure tables on Tcl 9
```

The `tcl-tests` check runs both, plus two linters:

- **nagelfar** checks syntax and variable use. `tests/lintdb.tcl` generates its database
  for our own commands from the loaded code (ensemble maps, `info args`, class
  definitions), so the lint follows the code.
- **tclint** checks style.

Expect in nixpkgs is built for Tcl 8.6, so the drivers run on 8.6. Running `parse.test` on
Tcl 9.0 as well keeps the pure code ready for 9.

## Why Tcl here

The bash these drivers replace had to rebuild Expect by hand: `/dev/tcp`, `read -t`
loops, partial-line buffers and numbered markers. In Tcl, Expect does that work. The event
loop (`chan event`, `vwait`) watches QEMU's output while a command runs, and TclOO keeps
each guest's state in one object instead of a set of bash arrays. The scripts that run
inside the guests (`homa-smoke`, `homa-node-stats`, `homa-qdisc`) stay bash, since the
guests have no Tcl, and are shellchecked as before.
