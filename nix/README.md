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
- **Build status per kernel:** [`docs/STATUS.md`](docs/STATUS.md)
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

---

## Testing against different kernels

Every kernel series has its own targets, so you can build or boot exactly the one you want:

| Series | Source | `homa-module-<s>` | `homa-microvm[-test]-<s>` | Status on `main` |
|---|---|---|---|---|
| `7_3` (default) | nixpkgs `linuxPackages_latest` | ✅ builds | ✅ boots, smoke test passes | supported |
| `7_0`, `7_1`, `7_2` | kernel.org tarballs (`kernel-src.nix`) | ✅ compile check | — (no bootable kernel yet) | supported |
| `6_12` | nixpkgs | ✅ builds | ✅ boots, smoke test passes | supported |
| `6_18` | nixpkgs (6.18.57) | ❌ | ❌ | stable backported the 7.x socket API changes; see `docs/STATUS.md` |
| `6_1`, `6_6` | nixpkgs | ❌ | ❌ | below Homa's supported range |
| `local` | your checkout, `HOMA_LINUX_SRC=...` with `--impure` | ✅ compile check | — | e.g. net-next |

```sh
nix build .#homa-module-6_12          # homa.ko for one kernel
nix build .#homa-build-matrix         # try every kernel; result/summary.md is the table
nix run   .#homa-microvm-test-6_12    # boot that kernel and run the smoke test
nix run   .#homa-microvm-6_12         # the same guest, interactive (root, no password)
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
HOMA_LINUX_SRC=~/src/linux nix build --impure .#homa-module-local   # your kernel checkout
nix build .#homa-utils[-debug]       # user-space tools (util/); -debug adds ASan
nix build .#homa-tests               # build + run the unit tests (ASan)

nix run   .#homa-microvm-test        # default kernel: insmod, echo, GRO/RPS, rmmod
nix run   .#homa-microvm-test-<s>    # ... on one kernel
nix run   .#homa-microvm-test-debug  # ... under a KASAN/KMEMLEAK kernel (slow)
nix run   .#homa-microvm[-<s>]       # interactive guest

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
| `devshell.nix` + `shell-functions/` | the dev shell |
| `oci.nix` | user-space OCI image |
| `microvms/` | per-kernel microVM guests, the in-guest smoke test, and the orchestrator |
| `analysis/` | tiered static analysis (quick/standard/deep) |
| `fuzz/` | libFuzzer harnesses for wire (de)serialization |

Reports from the analysis and fuzzing runs are in [`../analysis-reports/`](../analysis-reports/).
