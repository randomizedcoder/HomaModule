# nix/microvms/tcl: the lifecycle drivers, in Tcl and Expect

The lifecycle tests boot QEMU guests and drive them from the host, phase by phase, over
each guest's consoles. This directory is the code that does the driving: a small Tcl
package, `homa::lc`, and one driver script per test. Nix (`../host/tcl.nix`) packages each
driver as a command and passes it its configuration as a JSON file. That way, every port,
timeout and netem setting still comes from `../constants.nix`.

| Command                          | Driver                   | Nix wrapper                  |
|----------------------------------|--------------------------|------------------------------|
| `homa-lifecycle[-<series>]`      | `bin/lifecycle.tcl`      | `../host/lifecycle.nix`      |
| `homa-pair-lifecycle[-<series>]` | `bin/pair-lifecycle.tcl` | `../host/pair-lifecycle.nix` |
| `homa-vm-matrix`                 | `bin/vm-matrix.tcl`      | `../host/matrix.nix`         |

```sh
nix run .#homa-lifecycle-7_3          # one guest: boot, smoke, module cycles, dmesg, poweroff
nix run .#homa-pair-lifecycle-6_12    # two guests: traffic, netem loss, Homa's qdisc
HOMA_VM_LOGDIR=/tmp/lc nix run .#homa-lifecycle   # keep the logs somewhere known
HOMA_VM_JOBS=4 nix run .#homa-vm-matrix            # every VM test, at most 4 at once
nix build .#checks.x86_64-linux.tcl-tests          # the tests and lint below
nix run .#homa-tcl-test -- -file wait.test          # some of the tests (see Tests)
nix run .#homa-tcl-lint                             # just the lint
```

## Files

| File | Package | What it is |
|---|---|---|
| `protocol.tcl` | `homa::lc::protocol` | The console's end-marker protocol (below): `protocol wrap` builds the line to send, `protocol line` reads one line back. Pure; only `console.tcl` uses it. |
| `parse.tcl` | `homa::lc::parse` | Pure functions that read guest output: counters and their deltas, cp_node lines, netem stats (`parse netemCheck`), oopses, smoke verdicts. An ensemble: `parse field $line P99`. |
| `report.tcl` | `homa::lc::report` | Pure functions that format results: verdicts, phase lines, `summary.md` rows, counter deltas, a pair traffic run's detail (`report trafficDetail`) and `homa-vm-matrix`'s rows. |
| `console.tcl` | `homa::lc::console` | `Console`, a TclOO class. It runs one shell command at a time over a guest console with Expect, and returns `{rc out}`. |
| `lc.tcl` | `homa::lc` | `Table`, the phase table: it times each phase, prints its line and writes `summary.md` with the VERDICT. `Node`, one guest: its QEMU process, its consoles, and the phases every test runs on each guest; `Node phase` runs a phase that needs the guest's shell. `Batch` runs whole tests as child processes, up to a job limit, through the event loop. `waitFor` (below), `readFile` and `writeFile`. |
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
humans both read these, so the format is fixed (`report phaseLine`):

```
  phase 3 smoke: PASS (5210 ms): HOMA_SMOKE_PASS
VERDICT: FAIL (2 phases)
```

A phase script runs in the caller's scope and gives `{rc detail}`, as its value or with
`return`. An rc of 0 is a PASS, `skip` is a SKIP, and any other integer is a FAIL. Anything
else fails only that phase, and the run goes on: an error (its stack is appended to
`phase-errors.log` in the log directory), a `break` or `continue`, or a result without a
valid rc. Once a guest's shell is gone, the phases that need it (`Node phase`) SKIP.

Waiting is done by `waitFor ms interval condition`: it checks an expression in the caller's
scope every `interval` ms, handling pending events (QEMU's output) in between, and returns
1 once it is true or 0 at the deadline. `Node` waits for its console ports, the first kernel
line and QEMU's exit with it.

## Tests

Every test is a row in a table, with a description, a category (positive, negative,
boundary or corner), its input, and the expected result or error (`testTable` in
`tests/helpers.tcl`):

```tcl
testTable combine {
    {"the first failure is kept" positive {0 1} ok 1}
    ...
} {report combine {*}$input}
```

| File | Covers |
|---|---|
| `tests/protocol.test` | `protocol wrap` and `protocol line`: markers, stale markers, CRs, bad ids |
| `tests/parse.test` | every `parse` function |
| `tests/report.test` | every `report` function, `trafficDetail` and `matrixRow` included |
| `tests/wait.test` | `waitFor`: at once, before and at the deadline, bad arguments, nested waits |
| `tests/console.test` | `Console`, against a real bash behind a local socket: timeouts, eof, stale markers, CRLF, split writes, 20000-line outputs |
| `tests/table.test` | `Table`: verdicts, the phase lines, `summary.md`, errors, `return`, `break` and `continue` inside phases, `phase-errors.log` |
| `tests/node.test` | `Node`'s phases end to end, against `tests/fakeqemu.tcl`: a fake QEMU that writes a serial log and serves bash on the console port, booting cleanly, with a kernel BUG, with a shell that never answers, never listening, or not starting at all; and `Node phase` |
| `tests/files.test` | `readFile` and `writeFile`: UTF-8 whatever the locale, missing and empty files, bytes that are not UTF-8, appends |
| `tests/batch.test` | `Batch`: exit codes, signals, a command that cannot start, each test's own directory, the job limit, bad limits and duplicate names; `withEnv`, and `HOMA_VM_LOGDIR` left as it was |
| `tests/style.test` | the sources themselves: every proc, method and constructor has `Arguments:` (if it takes any), `Results:` and `Side effects:`; no `eval`; no `namespace export *` |

Run them, or part of them, with `homa-tcl-test`. Its options go to tcltest, and each row is
a test named `<table>-<n>`:

```sh
nix run .#homa-tcl-test                                   # all of them, Tcl 8.6
nix run .#homa-tcl-test -- -file wait.test                # one file
nix run .#homa-tcl-test -- -file "parse.test report.test" # several
nix run .#homa-tcl-test -- -match 'trafficDetail-*'       # one table
nix run .#homa-tcl-test -- -match waitFor-3               # one row
nix run .#homa-tcl-test -- -verbose bpe -match 'delta-*'  # each test's body, pass and error
nix run .#homa-tcl-test -- --tcl9                         # the pure files on Tcl 9.0
nix run .#homa-tcl-lint                                   # the linters below
```

The app runs a copy of the tests as the flake sees them (a new file needs `git add -N`).
The `tcl-tests` check runs the lint, the whole suite on Tcl 8.6 and the pure files on Tcl
9.0; the lint is:

- **nagelfar** checks syntax and variable use. `tests/lintdb.tcl` generates its database
  for our own commands from the loaded code (ensemble maps, `info args`, class
  definitions), so the lint follows the code.
- **tclint** checks style.

It also checks that `parse.tcl`'s oops regex (`oopsRe`) is the same as
`constants.oopsRegex`, which the guests' own dmesg checks use.

Expect in nixpkgs is built for Tcl 8.6, so the drivers run on 8.6. Running the pure tables
on Tcl 9.0 as well keeps `protocol`, `parse` and `report` ready for 9.

## Why Tcl here

The bash these drivers replace had to rebuild Expect by hand: `/dev/tcp`, `read -t`
loops, partial-line buffers and numbered markers. In Tcl, Expect does that work. The event
loop (`chan event`, `waitFor`) watches QEMU's output while a command runs, and TclOO keeps
each guest's state in one object instead of a set of bash arrays. The scripts that run
inside the guests (`homa-smoke`, `homa-node-stats`, `homa-qdisc`) stay bash, since the
guests have no Tcl, and are shellchecked as before.
