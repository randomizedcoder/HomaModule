# Homa — Nix flake

This directory holds a modular [Nix](https://nixos.org) setup for the Homa kernel module. One
command gives you a working toolchain. Others build `homa.ko` against many kernels, boot each
kernel in a microVM and run Homa traffic in it, run static analysis, and fuzz the wire
protocol.

## Goals

- **Easy onboarding:** build and test Homa on any Linux distro without hunting for kernel
  headers or matching compiler versions.
- **Reproducibility:** `flake.lock` pins every input (nixpkgs, kernels, tools), so a build or
  test result means the same thing on every machine. No more "it worked on my machine".
- **Test many kernels:** Homa tracks a moving kernel API. The flake builds the module against
  every kernel series below and boots real kernels to load and exercise it.
- **No effect on the host:** nothing is installed system-wide. Tools exist only inside
  `nix develop` or a `nix build`/`nix run`.

> ⚠️ **Linux only.** The microVM targets also need KVM (`/dev/kvm` readable and writable by
> your user).
>
> The flake lives on the `nix-flake` branch of
> [randomizedcoder/HomaModule](https://github.com/randomizedcoder/HomaModule/tree/nix-flake),
> rebased onto upstream `main`. It is not part of upstream.

- **Design and rationale:** [`docs/DESIGN.md`](docs/DESIGN.md)
- **Status, findings and follow-ups:** [`STATUS.md`](STATUS.md)
- **Next: Homa traffic between pairs of VMs:** [`microvms/PLAN-pairs.md`](microvms/PLAN-pairs.md)

---

## Quick start

### 1. Install Nix

Pick a **multi-user** (daemon) or **single-user** install:

- [Multi-user](https://nix.dev/manual/nix/2.24/installation/#multi-user), recommended on most
  distros:
  ```sh
  bash <(curl -L https://nixos.org/nix/install) --daemon
  ```
- [Single-user](https://nix.dev/manual/nix/2.24/installation/#single-user), no daemon, with the
  store owned by your user:
  ```sh
  bash <(curl -L https://nixos.org/nix/install) --no-daemon
  ```

#### Video walkthroughs

| Platform | Video |
|---|---|
| Ubuntu | [Installing Nix on Ubuntu](https://youtu.be/cb7BBZLhuUY) |
| Fedora | [Installing Nix on Fedora](https://youtu.be/RvaTxMa4IiY) |

### 2. Enable flakes (once)

```sh
test -d /etc/nix || sudo mkdir /etc/nix
echo 'experimental-features = nix-command flakes' | sudo tee -a /etc/nix/nix.conf
```

Or per command: `nix --extra-experimental-features 'nix-command flakes' develop`.
See also the [Nix flakes wiki](https://nixos.wiki/wiki/flakes).

### 3. Get the code and enter the dev shell

```sh
git clone -b nix-flake https://github.com/randomizedcoder/HomaModule.git
cd HomaModule
nix develop
```

The shell has the kernel build tree for the default kernel (`$KDIR`), the compilers, the
analysis tools, and helper functions: `homa-build`, `homa-test`, `homa-clean`,
`homa-checkpatch`, `homa-lint`.

The first run downloads and builds the dependencies, which can take a few minutes. After that
they come from `/nix/store` and start almost instantly.

### 4. Try it: boot a kernel and run Homa

```sh
nix run .#homa-microvm-test-7_3
```

This boots a 7.3 kernel in a microVM, loads `homa.ko`, runs echo RPCs over loopback and then
between two network namespaces with GRO and RPS on, unloads the module, and checks dmesg:

```
HOMA_SMOKE_START kernel=7.3.0
HOMA_SMOKE_INSMOD_OK
HOMA_SMOKE_LSMOD_OK
HOMA_SMOKE_ECHO responses=6 (want 6)
HOMA_SMOKE_GRO responses=6 (want 6) homa_gro_receive calls=1724 homa_set_softirq_cpu calls=464
HOMA_SMOKE_RMMOD_OK
HOMA_SMOKE_DMESG_OK
HOMA_SMOKE_PASS
VERDICT: PASS
```

The whole run takes about 15 seconds once the kernel is in the store.

### 5. Homa between two VMs

```sh
nix run .#homa-pair-test
```

This boots two VMs, `node0` and `node1`, joined by a private Ethernet link. The link is
QEMU UDP between two localhost ports, so it needs no root, tap or bridge. Homa then runs
over that link between two separate kernels:

```
--- node0 (server)
HOMA_PAIR_SERVER_START host=node0 kernel=7.3.0
HOMA_PAIR_SERVER_INSMOD_OK
HOMA_PAIR_SERVER_SERVERS_OK
HOMA_PAIR_SERVER_READY
HOMA_PAIR_SERVER_CLIENT_REPORT PASS
HOMA_PAIR_SERVER_RMMOD_OK
HOMA_PAIR_SERVER_DMESG_OK
HOMA_PAIR_SERVER_PASS
--- node1 (client)
HOMA_PAIR_START host=node1 kernel=7.3.0
HOMA_PAIR_INSMOD_OK
HOMA_PAIR_PING_OK
HOMA_PAIR_PEER_READY_OK
HOMA_PAIR_ECHO responses=6 (want 6) data+grant packets=1335
HOMA_PAIR_ECHO_OK
HOMA_PAIR_CPNODE_homa ... homa_w4 clients: 0.40 Kops/sec, 0.19 Gbps out, 0.19 Gbps in, RTT (us) P50 522.07 P99 33163.40 ...
HOMA_PAIR_CPNODE_HOMA_OK
HOMA_PAIR_CPNODE_tcp ... tcp_w4 clients: 0.40 Kops/sec, 0.15 Gbps out, 0.15 Gbps in, RTT (us) P50 372.96 P99 22185.27 ...
HOMA_PAIR_CPNODE_TCP_OK
HOMA_PAIR_RMMOD_OK
HOMA_PAIR_DMESG_OK
HOMA_PAIR_PASS
VERDICT: PASS
```

The client does the following, in order:
1. pings `node0`;
2. runs echo RPCs from 100 B to 1 MB across the link;
3. drives a few seconds of Homa's `cp_node` workload `w4`;
4. drives the same workload over TCP for comparison.

Then both VMs unload the module and check dmesg. A run takes about 35 seconds once
cached. The link is emulated and the VMs share host CPUs, so the rates show that traffic
flows, not how fast Homa is.

---

## Testing against different kernels

Every kernel series has its own targets, so you can build or boot exactly the one you want:

| Series | Source | `homa-module-<s>` | `homa-microvm[-test]-<s>` | Status on `main` |
|---|---|---|---|---|
| `7_3` (default) | nixpkgs `linuxPackages_latest` | ✅ builds | ✅ boots, smoke and pair tests pass | supported |
| `7_0`, `7_1`, `7_2` | kernel.org tarballs (`kernel-src.nix`) | ✅ compile check | — (no bootable kernel yet) | supported |
| `6_12` | nixpkgs | ✅ builds | ✅ boots, smoke and pair tests pass | supported |
| `6_18` | nixpkgs (6.18.57) | ❌ | — | stable backported the 7.x socket API changes; see [`STATUS.md`](STATUS.md) F1 |
| `6_1`, `6_6` | nixpkgs | ❌ | — | below Homa's supported range |
| `local` | your checkout, `HOMA_LINUX_SRC=...` with `--impure` | ✅ compile check | — | e.g. net-next |

```sh
nix build .#homa-module-6_12          # homa.ko for one kernel
nix build .#homa-build-matrix         # try every kernel; result/summary.md is the table
nix run   .#homa-microvm-test-6_12    # boot that kernel and run the smoke test
nix run   .#homa-microvm-6_12         # the same guest, interactive (root, no password)
nix run   .#homa-pair-test-6_12-7_3   # Homa between a 6.12 server VM and a 7.3 client VM
```

VM and pair targets exist only for kernels where the module builds (`vmSeries` in
`kernel.nix`). Pair targets cover every server/client combination: `6_12-6_12`, `6_12-7_3`,
`7_3-6_12` and `7_3-7_3`. The mixed pairs check that Homa built for one kernel talks to Homa
built for another. Each pair has its own link port, so they can all run at once:

```sh
for p in 6_12-6_12 6_12-7_3 7_3-6_12 7_3-7_3; do nix run .#homa-pair-test-$p & done; wait
```

Each VM boots the same `kernelPackages` the module was built against, so the module's version
check (vermagic) always matches. The host `/nix/store` is shared into the guest, so nothing
is copied into an image.

---

## All commands

```sh
nix develop                          # dev shell (toolchain + analysis tools)

nix build .#homa-module              # homa.ko (release) against the default kernel (7.3)
nix build .#homa-module-debug        # homa.ko (debug: -g -O1)
nix build .#homa-module-<series>     # one kernel (table above)
nix build .#homa-build-matrix        # every kernel -> result/summary.md (never fails)
nix build .#homa-module-riscv64      # cross-compiled homa.ko (also -aarch64, and -strip)
nix build .#homa-cross-matrix        # riscv64 + aarch64: homa.ko and util/ -> summary.md
HOMA_LINUX_SRC=~/src/linux nix build --impure .#homa-module-local   # your kernel checkout
nix build .#homa-utils[-debug]       # user-space tools (util/); -debug adds ASan
nix build .#homa-tests               # build + run the unit tests (ASan)

nix run   .#homa-microvm-test        # default kernel: insmod, echo, GRO/RPS, rmmod
nix run   .#homa-microvm-test-<s>    # ... on one kernel
nix run   .#homa-microvm-test-debug  # ... under a KASAN/KMEMLEAK kernel (slow)
nix run   .#homa-lifecycle[-<s>]     # host-driven, timed phases over ttyS0 + virtio console
nix run   .#homa-microvm[-<s>]       # interactive guest
nix run   .#homa-pair-test           # two VMs: echo + cp_node (Homa, TCP) across a link
nix run   .#homa-pair-test-<s>-<c>   # ... server kernel <s>, client kernel <c>
nix run   .#homa-pair-exp            # latency sweep: cp_node per sysctl setting + metric deltas
nix run   .#homa-vm-matrix           # every VM test and pair in parallel -> summary table
nix run   .#homa-pair-exp-socket     # ... over QEMU's TCP socket link (STATUS.md F2)

nix build .#homa-image[-debug]       # OCI user-space image (docker load < result)

nix build .#analysis-quick           # python + shell + clang-format (no kernel needed)
nix build .#analysis-standard        # + cppcheck + clang-tidy
nix build .#analysis-deep            # + sparse (endianness) + smatch

nix build .#fuzz                     # standalone wire-decoder + selftest harnesses
FUZZ_TIME=300 ./result/bin/run-fuzzers   #   ... run them for 5 minutes
nix build .#fuzz-run                 # bounded run -> summary.txt / count.txt / crashes
nix build .#fuzz-deep                # fork mode + dictionary + crash dedup
nix build .#fuzz-cov                 # coverage of the wire decoder
nix build .#fuzz-selftest            # canary gate (fails if the harness is vacuous)
nix build .#fuzz-mock                # real Homa parsers against a kernel mock

nix flake show                       # list every output
nix flake check                      # run the checks
```

`HOMA_VM_LOGDIR=<dir>` keeps the microVM console logs in a directory of your choice. By
default each run makes a fresh `mktemp -d` and prints its path.

## Module map

| File | Concern |
|---|---|
| `kernel.nix` | default kernel, `KDIR`, per-series matrix |
| `kernel-src.nix` | prepared kernel trees from kernel.org tarballs or a local checkout |
| `patches/` | upstream-pending Homa fixes the flake applies (currently none) |
| `packages.nix` | toolchain inventory (build deps, dev and analysis tools, python env) |
| `env-vars.nix` | dev-shell environment fragment |
| `module.nix` | `homa.ko` derivations (debug/release, per kernel) and `homa-build-matrix` |
| `userspace.nix` | `util/` tools and the `test/` unit harness |
| `cross.nix` | riscv64 and aarch64 cross builds (`pkgsCross`) and `homa-cross-matrix` |
| `devshell.nix` + `shell-functions/` | the dev shell |
| `oci.nix` | user-space OCI image |
| `microvms/` | per-kernel microVM guests, the in-guest smoke and pair tests, and the orchestrators |
| `analysis/` | tiered static analysis (quick/standard/deep) |
| `fuzz/` | libFuzzer harnesses for wire (de)serialization |

Reports from the analysis and fuzzing runs are in [`../analysis-reports/`](../analysis-reports/).
