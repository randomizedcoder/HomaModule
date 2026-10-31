# nix/microvms/guest: what runs inside the VMs

| File | What it is |
|---|---|
| `mkVm.nix` | the guest: a NixOS system built with [microvm.nix](https://github.com/microvm-nix/microvm.nix), given a kernel, its `homa.ko`, and a role (smoke test, pair node, lifecycle or interactive) |
| `smoke.nix` | `homa-smoke`: insmod, echo RPCs over loopback and across two netns, rmmod, dmesg |
| `pair.nix` | the pair test's server and client scripts, and the sweep mode of `homa-pair-exp` |
| `metrics.nix` | `homa-node-stats` (Homa's counters, summed over cores, plus NIC and qdisc drops) and the awk that diffs two of its snapshots |
| `qdisc.nix` | `homa-qdisc on/off/show`: Homa's queuing discipline on eth1 |

The scripts are bash, built with `writeShellApplication`, which runs shellcheck on them at
build time and sets `PATH` to exactly the tools listed in `runtimeInputs`. They run in the
guest, which has no Tcl.

## Output markers

A guest script reports through lines on its console that the host greps for:
`HOMA_SMOKE_<PHASE>_OK`, then exactly one of `HOMA_SMOKE_PASS` and
`HOMA_SMOKE_FAIL:<phase>` (pair: `HOMA_PAIR_...` and `HOMA_PAIR_SERVER_...`). The host
side ([`../host`](../host)) and `homa-vm-matrix` parse these lines, so changing one means
changing its parser too.

## A guest, in Nix terms

`mkVm.nix` calls `nixpkgs.lib.nixosSystem`, as a NixOS machine's own configuration would,
with the microvm.nix module added. The result's `config.microvm.declaredRunner` is a
script that starts QEMU with that system. The guest gets its kernel from
`boot.kernelPackages`, and `homa.ko` by store path. The host's store is mounted over
9p, so the guest sees the exact files the host built.
