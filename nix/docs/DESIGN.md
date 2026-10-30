# Homa Nix Flake — Design

> Status: **living design document**. This is the durable *why* and *how* behind the
> `nix/` tree. For a quick-start command list see [`../README.md`](../README.md); for
> live build progress see [`../STATUS.md`](../STATUS.md).

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
  STATUS.md                   # status per kernel/target, findings, follow-ups
  docs/
    DESIGN.md                 # this file
  kernel.nix                  # kernelPackages selection (linux_latest) + KDIR + per-series matrix
  kernel-src.nix              # prepared kernel trees from kernel.org tarballs / a local checkout
  patches/                    # upstream-pending fixes applied to the Homa source (homaLib.src)
  packages.nix                # nativeBuildInputs / buildInputs / devTools / pythonEnv / allPackages
  env-vars.nix                # shell env fragment (CC/CXX, KDIR, ARCH, PYTHON)
  module.nix                  # homa.ko derivation, enableDebug switch  -> homa-module[-debug|-<series>],
                              #   homa-build-matrix
  userspace.nix               # util/ + test/ derivations              -> homa-utils[-debug], homa-tests
  devshell.nix                # mkShell composing the above
  shell-functions/*.nix       # bash helper fragments (homa-build/test/clean/checkpatch/lint)
  oci.nix                     # userspace OCI image                    -> homa-image[-debug]
  microvms/
    constants.nix             # hostname, resources, timeouts
    mkVm.nix                  # parameterised guest (kernelPackages, 9p store, HOMA_KO, autoTest)
    smoke.nix                 # in-guest smoke test (systemd oneshot, sentinels on the console)
    lib.nix                   # host runner: boot, capture console, grep sentinels -> verdict
    default.nix               # assembly -> per-kernel microvm packages + test runners
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
default `kernelPackages = pkgs.linuxPackages_latest` (7.3), overridable, because Homa is
being ported forward to 7.x. Every derivation builds a subset of the source from
`homaLib.src` (`nix/lib`) rather than `self`, with `nix/patches/` applied: they can carry
an upstream-pending fix that the default kernel needs. It carried
the 7.1 port (fork draft #12) until upstream landed it as `e65a5c0`, and is empty now. A
patch that upstream has absorbed stops applying, which fails the build at patchPhase: that
is the cue to delete it.

Kernels come from two places:

- **nixpkgs** (`kernelConfig.matrix`, keyed by series: `6_1 6_6 6_12 6_18 7_3`). Each
  series probed with `tryEval`, so EOL removals drop out instead of breaking evaluation.
  These get a real `homa-module-<series>` and a bootable `homa-microvm-test-<series>`.
- **Source** (`kernel-src.nix`): series nixpkgs has already dropped (7.0, 7.1, 7.2 from
  pinned kernel.org tarballs) and, with `--impure` and `HOMA_LINUX_SRC=/path/to/linux`, a
  local checkout (`local`). Each is `olddefconfig` + `modules_prepare` in an O= tree using
  nixpkgs' newest kernel config: about 2.5 minutes and 450 MB, versus a full kernel build.
  There is no `vmlinux` or `Module.symvers`, so `homa-module-<series>` against these is a
  compile check built with `KBUILD_MODPOST_WARN=1`, not a loadable module.

`homa-build-matrix` builds Homa against every kernel above in one derivation and writes
`summary.md` plus per-kernel logs. It records failures rather than failing, so one broken
kernel never hides the others.

The unit harness and kernel-mock fuzzers stay on 6.18 (`unitKernelPackages`,
`nix/unit-kdir`): `test/mock.c` has to support the kernel's headers, and that lags.

## 6. microVM approach

For a kernel module, a container is the wrong unit — you need a real kernel. The microVM
(astro/microvm.nix, adapted from `uds-rdma-proxy` and xtcp2) provides one per kernel:

- `mkVm.nix` builds a guest `nixosSystem` for a given `kernelPackages` and loads a
  `homa.ko` built against that same set (avoids vermagic drift). It uses qemu's `pc`
  machine: on the default `microvm` machine the guest's 8250 UART never registers as
  ttyS0 and the console goes silent after early boot.
- The host `/nix/store` is mounted into the guest over **9p**, so the exact `.ko` store
  path is visible; it is exported to the guest as `environment.variables.HOMA_KO`.
- **The test runs inside the guest** (xtcp2 pattern). With `autoTest = true`, `smoke.nix`
  runs as a systemd oneshot with `StandardOutput=journal+console`: `insmod` →
  `/proc/modules` → loopback echo RPCs (`demo_server1` ← `demo_client1`, 6 messages from
  100 B to 1 MB, through sendmsg and recvmsg) → the same echo between two network
  namespaces over veth with GRO on, TSO off (veth only uses GRO then) and
  `rps_sock_flow_entries` set, with kprobes requiring calls to `homa_gro_receive` and
  `homa_set_softirq_cpu` (the RPS flow-table code that 7.1 changed) → `rmmod` → dmesg gate. It prints
  `HOMA_SMOKE_<phase>_OK` lines, then `HOMA_SMOKE_PASS` or `HOMA_SMOKE_FAIL:<phase>`, and
  powers the VM off.
- `lib.nix` on the host only boots the runner under `timeout`, captures the console, and
  greps the sentinels. There is no expect script, no TCP serial port and no shell prompt to
  match, so tests for different kernels can run in parallel.
- **Debug variant** (`withSanitizers`) boots a KASAN/KMEMLEAK kernel, allots more RAM,
  inflates the timeout, and adds a `SANITIZER` phase that fails on any KASAN, UBSAN or
  kmemleak report.

Exposed: `homa-microvm[-<series>|-debug]` (interactive runner, root autologin) and
`homa-microvm-test[-<series>|-debug]` (`nix run` verdicts).

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
symbolized `crashes/<harness>/repro-<sig>.txt`, one per sanitizer signature), `fuzz-deep`
(`nix run`: fork mode + dictionary, `FUZZ_DEEP_TIME`/`FORKS`/`MAXLEN`),
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
