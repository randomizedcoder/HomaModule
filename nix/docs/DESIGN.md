# Homa Nix Flake — Design

> Status: **living design document**. This is the durable *why* and *how* behind the
> `nix/` tree. For a quick-start command list see [`../README.md`](../README.md); for
> live build progress see [`STATUS.md`](STATUS.md).

## 1. Goal

`HomaModule` is an out-of-tree Linux kernel transport module (`homa.ko`) with C++
user-space tools (`util/`), a kselftest-style unit-test harness (`test/`, built with
AddressSanitizer), and ~23 Python analysis scripts. Historically it ships only hand-written
GNU Makefiles — no Nix, no CI, no linter config.

This flake adds a **reproducible, modular Nix layer** on top, giving a fork of the repo:

1. A **dev shell** with the full toolchain (kernel build deps, gcc/g++, Python + matplotlib/numpy, static-analysis tools).
2. **Debug + release derivations** of both the kernel module and the user-space tools.
3. A **microVM** that boots a matching kernel and actually `insmod`s and smoke-tests `homa.ko`.
4. A **tiered static-analysis** framework (Python/shell/format → clang-tidy/cppcheck → sparse/smatch).
5. A **fuzzing** framework focused on Homa's wire-format **(de)serialization** paths.
6. Two generated reports: a **static-analysis report** and a **fuzzing report**.

Everything is **purely additive** — no existing repo file is modified (except an optional
`.gitignore` line for `result*` symlinks).

## 2. Reference patterns adapted

This design does not invent conventions; it adapts three existing, proven Nix setups:

| Concern | Reference project | What we take |
|---|---|---|
| Modular `nix/` layout, debug/release switch, OCI image | `xdp2` | one-concern-per-file modules wired by explicit `import`; a boolean `enableDebug` on a shared derivation; `dockerTools.buildLayeredImage` |
| microVM that loads an out-of-tree `.ko` | `uds-rdma-proxy` | guest `nixosSystem` + `microvm.nixosModules.microvm`, **co-pinned** `kernelPackages` for guest boot and module build, 9p `/nix/store` share, `insmod $KO` driven over an `expect` console, KASAN debug variant |
| Userspace libFuzzer framework | `rocm-systems` | `-fsanitize=fuzzer,address,undefined`, `hardeningDisable=["all"]`, attrset-of-recipes harnesses, a `run-fuzzers` wrapper, `summary.txt`/`count.txt` output, `fuzz-deep` crash dedup, `fuzz-cov`, a `fuzz-selftest` canary gate |

## 3. Module map & composition

The flake follows the xdp2 style: **flake-utils**, a plain `outputs` function (no
flake-parts), and explicit `import ./nix/<mod>.nix { ... }` wiring — no auto-discovery.
Modules never read `self`/inputs; they receive `pkgs`, `lib`, and already-built
derivations as arguments, which keeps them independently testable.

```
flake.nix                     # inputs (nixpkgs unstable, flake-utils, microvm), wiring, usage header
nix/
  README.md                   # quick-start + command cheat-sheet
  docs/
    DESIGN.md                 # this file
    STATUS.md                 # living progress tracker
  kernel.nix                  # kernelPackages selection (linux_latest) + KDIR + LTS matrix
  packages.nix                # nativeBuildInputs / buildInputs / devTools / pythonEnv / allPackages
  env-vars.nix                # shell env fragment (CC/CXX, KDIR, ARCH, PYTHON)
  module.nix                  # homa.ko derivation, enableDebug switch  -> homa-module[-debug]
  userspace.nix               # util/ + test/ derivations              -> homa-utils[-debug], homa-tests
  devshell.nix                # mkShell composing the above
  shell-functions/*.nix       # bash helper fragments (homa-build/test/clean/checkpatch/lint)
  oci.nix                     # userspace OCI image                    -> homa-image[-debug]
  microvms/
    constants.nix             # ports, hostnames, kernelPackage, arch table, timeouts
    mkVm.nix                  # parameterised guest (co-pinned kernel, 9p store, HOMA_KO)
    lib.nix                   # phased smoke-test orchestrator (writeShellApplication)
    default.nix               # assembly -> microvm packages + test runners
    scripts/vm-expect.exp     # "run one command in the guest, capture stdout" primitive
  analysis/
    default.nix               # composition root: analysis-quick|standard|deep + summary.txt
    compile-db.nix            # compile_commands.json via bear (for clang-tidy/cppcheck)
    clang-tidy.nix cppcheck.nix clang-format.nix
    sparse.nix smatch.nix     # kernel-aware (need the kernel tree)
    python.nix shell.nix      # ruff/mypy ; shellcheck/shfmt (shebang-aware discovery)
  fuzz/
    default.nix               # composition root: fuzz / fuzz-run / fuzz-deep / fuzz-cov / fuzz-selftest
    tools/fuzz{,-deep,-cov,-selftest}.nix
    harness/                  # libFuzzer harness sources (see §7)
    dict/homa_wire.dict       # wire-format dictionary
    corpus-seeds/<type>/      # one valid packet per Homa packet type
analysis-reports/
  static-analysis-report.md
  fuzzing-report.md
```

**Composition flow:** config modules (`kernel`, `packages`, `env-vars`) return
attrsets/shell-fragments → consumed by derivation modules (`module`, `userspace`,
`analysis/*`, `fuzz/*`) and the `devshell` → assembled into flake `outputs`. The microVM,
analysis, and fuzz subtrees each expose a `default.nix` aggregator.

## 4. Debug vs non-debug model

A single derivation module is instantiated twice via a boolean, mirroring xdp2's
`enableAsserts`:

- **Kernel module** (`module.nix`, `enableDebug ? false`): release builds with
  `MY_CFLAGS='-O2'`; debug builds with `MY_CFLAGS='-g -O1 -fno-omit-frame-pointer'`. Homa's
  Makefile already appends `-g` and has no formal `DEBUG` macro, so at the C level "debug"
  means optimization/symbols. **Real memory-safety coverage comes from the microVM's
  KASAN/KMEMLEAK debug kernel** (§6), not from a module CFLAG. This is stated honestly in
  the module header so nobody over-reads what `homa-module-debug` provides.
- **User-space** (`userspace.nix`): release mirrors `util/Makefile` (`-O3 -Wall -Werror`);
  debug mirrors `test/Makefile` (`-fsanitize=address -g`), including the documented
  `rhashtable.o -O2 -fno-sanitize=address` special case.

## 5. Kernel pinning strategy

`kernel.nix` is the single source of truth. nixpkgs is pinned to `nixos-unstable`. The
default `kernelPackages = pkgs.linuxPackages_6_12` — **the newest kernel in the current
nixpkgs that actually builds Homa** — and it is **overridable**. `kernel.nix` also exposes a
compile-test **matrix** (`linuxPackages_6_1/6_6/6_12`), a `latest` handle
(`linux_latest`, for the drift-demonstration target), and a `KDIR` override so the devshell
`make` can target any kernel, including the host's.

**Resolved API drift (why not the newest kernel):** Homa `main` targets ~Linux 6.17. At the
time of building, this nixpkgs offered `linux_latest` = **7.2.6**, against which `homa.ko`
fails to compile (upstream API drift in `homa_devel.c`/`homa_rpc.h` — not a flake bug), and
6.16/6.17/6.19 had already been **removed from nixpkgs as EOL**. The newest kernel that
still builds Homa is **6.12 LTS**, so it is the default; `homa-module-latest` builds against
`linux_latest` to reproduce the drift as Homa/nixpkgs move. The matrix + `KDIR` override are
the fallback mechanism, and outcomes are recorded in `STATUS.md`.

**Note:** this build host runs kernel 7.1.8 — newer than any nixpkgs package and not equal
to the pinned build kernel — so a built `.ko` is a **build artifact**. It is exercised
inside the microVM (which boots the co-pinned kernel), never `insmod`ed on the host.

## 6. microVM approach

For a kernel module, a container is the wrong unit — you need a real kernel. The microVM
(astro/microvm.nix, adapted from `uds-rdma-proxy`) provides one:

- `mkVm.nix` builds a guest `nixosSystem` and **co-pins the same `kernelPackages`** for
  both the guest boot and the `homa.ko` build (avoids vermagic drift).
- The host `/nix/store` is mounted into the guest over **9p**, so the exact `.ko` store
  path is visible; it is exported to the guest as `environment.variables.HOMA_KO`.
- `lib.nix` is a `writeShellApplication` orchestrator that runs a **phased smoke test**
  over a TCP console (via `scripts/vm-expect.exp`): boot → wait for prompt →
  `insmod $HOMA_KO` → `lsmod | grep ^homa` → dmesg banner → exercise a Homa socket
  (loopback sendmsg/recvmsg) → `rmmod` → scan dmesg for splats → verdict.
- **Debug variant** (`withSanitizers`) boots a KASAN/KMEMLEAK kernel, allots more RAM,
  inflates timeouts, and adds a dmesg splat gate that fails the run on any
  `KASAN`/`unreferenced object` hit.

Exposed: `homa-microvm[-debug]` (the runner package) and `homa-microvm-test[-debug]`
(`nix run` orchestrators).

## 7. Fuzzing — the (de)serialization focus

Homa's core job is moving packets, so **wire-format serialization/deserialization is the
primary fuzzing focus** — the code most likely to hide bounds, endianness, and emit/ingest
asymmetry bugs. Kernel code is fuzzed **in user space** with libFuzzer by reusing the
existing `test/mock.c` kernel-mock layer (which already provides `mock_skb_alloc` and
userspace substitutes for kernel functions) and the self-contained userspace dissector.

Wire types live in `homa_wire.h`; the packet-type byte sits at offset 13 in every header
(`enum homa_packet_type`: `DATA=0x10, GRANT=0x11, RESEND=0x12, RPC_UNKNOWN=0x13,
BUSY=0x14, CUTOFFS=0x15, FREEZE=0x16, NEED_ACK=0x17, ACK=0x18`).

**Focus A — deserialization (parse), one harness per packet type** (`harness/deser/`), so a
crash pinpoints the exact parser: `fuzz_data_pkt`→`homa_data_pkt`, `fuzz_grant_pkt`,
`fuzz_resend_pkt`, `fuzz_ack_pkt`, `fuzz_cutoffs_pkt`, `fuzz_need_ack_pkt`,
`fuzz_rpc_unknown_pkt`; plus `fuzz_dispatch`→`homa_dispatch_pkts` (whole-packet entry) and
`fuzz_gro`→`homa_gro_receive`/`homa_gso_segment` (the highest-risk `skb_transport_header`→
`homa_data_hdr` / `__skb_pull` bounds casts).

**Focus B — serialization + roundtrip differential** (`harness/roundtrip/`):
- `fuzz_roundtrip` — parse → re-emit via `homa_xmit_*`/`homa_message_out_init` → assert
  parse∘emit invariants (type, RPC id via `homa_local_id`, offsets/lengths survive a
  `__be*` roundtrip). Catches byte-order and asymmetry bugs a one-direction parse misses.
- `fuzz_differential` — same bytes into the kernel parse path and the userspace dissector
  (`dissect_homa`); divergence on type or key fields = a real discrepancy.

**Focus C — userspace dissector** (`harness/fuzz_dissector.c`) over `dissect_homa` alone:
the easy first win (no kernel mock) and the oracle for `fuzz_differential`.

**Static complement:** the `analysis` deep tier runs `sparse` with `-D__CHECK_ENDIAN__` to
statically vet the `__be16/__be32/__be64` handling in the same (de)serialization code.

**Targets:** `fuzz` (build all), `fuzz-run` (bounded run → `summary.txt`/`count.txt`/
symbolized `crashes/<h>/repro.txt`), `fuzz-deep` (fork-mode + dict + ASan-signature dedup),
`fuzz-cov` (llvm-cov replay, scoped to the wire functions), `fuzz-selftest` (injected-
overflow canary gate). Runner honors `FUZZ_TIME`/`FUZZ_WORKDIR`.

## 8. Static analysis — tiers

`analysis/default.nix` exposes `analysis-quick|standard|deep`, each a `runCommand` that
links per-tool outputs and writes a `summary.txt` with finding counts.

- **quick** (no kernel): `ruff` + `mypy` (shebang-aware discovery — Homa has extensionless
  `util/cp_*` Python scripts), `shellcheck` + `shfmt` (shebang-detected shell), `clang-format` check.
- **standard**: + a `bear`-built `compile_commands.json` → `clang-tidy` (bugprone/cert/
  clang-analyzer) + `cppcheck --enable=all --std=c11`.
- **deep**: + `sparse` (endianness on) + `smatch` + `checkpatch`/`kdoc` wrappers reusing
  the existing Makefile targets.

## 9. Deliverables & reports

The two reports are **separate documents** under `analysis-reports/`:
- `static-analysis-report.md` — per-tool findings, severity counts, which tiers ran vs were
  skipped (and why, e.g. kernel API drift).
- `fuzzing-report.md` — organized around the Focus A/B/C areas: per-type parse results, GRO/
  GSO casts, roundtrip/differential findings, endianness observations, coverage, reproducers.
