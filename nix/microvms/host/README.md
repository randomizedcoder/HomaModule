# nix/microvms/host: the commands that run the VM tests

Each file here makes one kind of `nix run` target. It starts the guest's QEMU runner
([`../guest`](../guest)), watches it, and prints the verdict.

| File | Targets | How |
|---|---|---|
| `smoke-test.nix` | `homa-microvm-test*` | bash: boots the guest under `timeout`, greps the serial log for `HOMA_SMOKE_PASS` |
| `pair-test.nix` | `homa-pair-test*`, `homa-pair-exp*` | bash: boots node0, waits for its link port, boots node1, greps both logs |
| `lifecycle.nix` | `homa-lifecycle*` | Tcl: [`../tcl/bin/lifecycle.tcl`](../tcl/bin/lifecycle.tcl) with this file's configuration |
| `pair-lifecycle.nix` | `homa-pair-lifecycle*` | Tcl: [`../tcl/bin/pair-lifecycle.tcl`](../tcl/bin/pair-lifecycle.tcl) |
| `matrix.nix` | `homa-vm-matrix` | Tcl: [`../tcl/bin/vm-matrix.tcl`](../tcl/bin/vm-matrix.tcl) runs every test above at once |
| `tcl.nix` | | `mkTclApp`, which packages a Tcl driver as a command, and the `tcl-tests` check |

## Configuration goes in as JSON

The Tcl drivers hold no settings of their own. Each `.nix` file here builds an attribute
set (QEMU runner paths, console ports, timeouts, the netem phases from
[`../constants.nix`](../constants.nix)), and `mkTclApp` writes it out with
`builtins.toJSON` and passes the file to the driver. So a timeout or a port is changed in
one place, in Nix, and the driver reads it.
