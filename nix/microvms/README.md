# nix/microvms: Homa in real kernels, in QEMU

Each test boots one or two small NixOS guests in QEMU, with the same kernel `homa.ko` was
built against, and loads the module there. The guests share the host's `/nix/store`
read-only, so nothing is copied into a disk image, and they need no root on the host: only
KVM (`/dev/kvm`) and some localhost ports.

| Target | Guests | What it checks |
|---|---|---|
| `homa-microvm-test[-<series>]` | 1 | the guest runs the smoke test at boot: insmod, echo RPCs over loopback and across two netns with GRO/RPS, rmmod, dmesg |
| `homa-lifecycle[-<series>]` | 1 | the host drives the guest over its consoles, phase by phase with timeouts: boot, smoke, module load/unload cycles, dmesg, poweroff |
| `homa-pair-test[-<s>-<c>]` | 2 | Homa between two VMs over a private link: echo, then cp_node with Homa and with TCP |
| `homa-pair-lifecycle[-<series>]` | 2 | the pair, driven over both nodes' consoles: traffic, netem loss and delay, Homa's qdisc |
| `homa-pair-exp[-socket]` | 2 | a latency sweep over sysctl settings ([`../STATUS.md`](../STATUS.md) F2) |
| `homa-vm-matrix` | all | every per-kernel test and every pair at once, and a summary table |
| `homa-vm-compare old new` | — | two matrix runs' logs, test by test: phase ids, names and verdicts, `HOMA_*` lines, `VERDICT` |
| `homa-tcl-test`, `homa-tcl-lint` | — | the drivers' tests (all, or `-file`/`-match`) and lint ([`tcl/README.md`](tcl/README.md)) |
| `homa-microvm[-<series>]` | 1 | an interactive guest (root, no password) |

`<series>` is each kernel in `vmSeries` ([`../kernel/config.nix`](../kernel/config.nix));
without it, the default kernel. Each test prints its log directory (`HOMA_VM_LOGDIR` to
choose one) and ends with a `VERDICT: PASS` or `VERDICT: FAIL` line.

## Layout

| Path | Runs | What it is |
|---|---|---|
| `default.nix` | | every target above, one function call each |
| `constants.nix` | | the numbers: guest sizes, timeouts, addresses, netem phases, the oops regex |
| `ports.nix` | | every host port, from one table; evaluation fails if two tests would share one |
| [`guest/`](guest/) | in the VM | the guest's NixOS configuration and the scripts it runs |
| [`host/`](host/) | on the host | the commands that boot the guests and judge the result |
| [`tcl/`](tcl/) | on the host | the Tcl/Expect drivers that the lifecycle tests and the matrix run |
| `PLAN-pairs.md` | | the design notes for the two-VM tests |

## Two ways to drive a guest

The simple tests (`homa-microvm-test`, `homa-pair-test`) let the guest drive itself: a
systemd unit runs the test script at boot and prints markers such as `HOMA_SMOKE_PASS` on
the serial console, then powers off. The host waits for QEMU to exit and greps the log.

The lifecycle tests keep the host in charge. The guest offers a root shell on a virtio
console, exposed as a localhost TCP port, and a Tcl/Expect driver sends one command at a
time and times each phase. That shows where a run failed or hung, and lets a test reach
into both nodes of a pair mid-run, to add netem loss or swap the qdisc.

## Ports

Tests that run at once must not share a host port. `ports.nix` hands them out from one
table: two console ports per lifecycle guest, four per pair lifecycle, and one link port
per pair (a `dgram` link also uses that port plus `pair.dgramPortOffset`). TCP and UDP
ports are separate. A clash is an evaluation error that names both owners.
