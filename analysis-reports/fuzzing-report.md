# Homa Fuzzing Report

*Generated from the Nix flake's fuzzing targets. Companion to
[`static-analysis-report.md`](static-analysis-report.md). Focus: Homa's wire-format
serialization/deserialization — see [`../nix/docs/DESIGN.md`](../nix/docs/DESIGN.md) §7.*

- **Date:** 2026-09-18
- **Toolchain:** clang/LLVM 21.1.8, libFuzzer + AddressSanitizer + UBSan
- **Default kernel for mock targets:** linux 6.12.110 (see the static-analysis report for the
  kernel-selection rationale)
- **Reproduce:** `nix build .#fuzz-run` · `.#fuzz-cov` · `.#fuzz-selftest` · `.#fuzz-mock`

## Summary

| Target | Kind | Result |
|---|---|---|
| `fuzz-selftest` | canary gate | **PASS** — injected 32→8-byte overflow detected (SIGABRT, rc=134) |
| `fuzz` / `fuzz-run` | Focus C: standalone wire decoder + selftest | **built + ran** 20 s each; **0 crashes** |
| `fuzz-cov` | coverage of the wire decoder | **100%** region/line/function/branch |
| `fuzz-mock` | Focus A/B: real-code kernel-mock harnesses | **20/23 TUs compile**; 3 block linking (see below) |

## Focus C — standalone wire decoder (`fuzz_dissector`)

A dependency-free decoder (`nix/fuzz/harness/fuzz_dissector.cc` +
`homa_wire_spec.h`) that mirrors Homa's on-wire layout (verified against `homa_wire.h`
with a `static_assert` on the type-byte offset = 11) and reproduces the per-type
header-length check (`header_lengths[type-DATA]` from `homa_plumbing.c`) plus the DATA
segment walk, all under ASan/UBSan.

- `nix build .#fuzz-run`: fuzzed `fuzz_dissector` and `fuzz_selftest` for 20 s each →
  **0 crash inputs**. The decoder handles arbitrary/truncated/oversized input safely.
- `nix build .#fuzz-cov` (llvm-cov):

  | File | Regions | Lines | Functions | Branches |
  |---|---|---|---|---|
  | `fuzz_dissector.cc` | 100% (11) | 100% (30) | 100% (2) | 100% (8) |
  | `homa_wire_spec.h` | 100% (21) | 100% (29) | 100% (2) | 100% (30) |

  The corpus fully covers the decode logic — the fuzzer is exercising every branch of the
  wire classifier and segment walk.

## Focus B — differential oracle (`fuzz_differential`)

`fuzz_differential.cc` classifies each input with the spec decoder and drives the same bytes
through the real kernel ingest path; the oracle is that the kernel must handle every input
safely (including spec-flagged malformed/too-short packets) with no sanitizer violation. It
is part of the kernel-mock set below and shares that set's build status.

## Focus A/B — kernel-mock harnesses (`fuzz-mock`)

These reuse Homa's existing user-space mock layer (`test/mock.c`) to feed fuzz bytes into
the **real** deserialization code — `homa_dispatch_pkts` and the per-type parsers
(`homa_data_pkt`, `homa_grant_pkt`, `homa_resend_pkt`, `homa_ack_pkt`, `homa_cutoffs_pkt`,
`homa_need_ack_pkt`, `homa_rpc_unknown_pkt`), the GRO path (`homa_gro_receive`), plus the
roundtrip/differential harnesses. To get coverage-guided instrumentation the module code
must be compiled by **clang** (`-fsanitize=fuzzer,address,undefined`), unlike the gcc-based
unit tests.

**Status: best-effort, currently blocked.** With the kernel include paths corrected for
nixpkgs' `source/` vs `build/` split, **20 of 23 translation units now compile with clang**
against the 6.12 headers. Three still fail on clang-vs-kernel incompatibilities, which
blocks the shared-object link (harnesses are therefore skipped, and this is reported in
`$out/status.txt` rather than failing the build):

| File | Blocking diagnostic |
|---|---|
| `homa_pool.c` | `use of undeclared identifier 'cpu_number'`; redefinition of `__preempt_count_add/sub` (x86 per-cpu/preempt asm under clang) |
| `test/mock.c` | `conflicting types for '__modver_version_show'` (MODULE_VERSION machinery) |
| `homa_outgoing.c` | `__compiletime_assert…: min(skb_frag_size(msg_frag) - bytes_to_skip, bytes_left) signedness error` — the kernel's checked `min()` rejects a signed/unsigned mix |

The last one is notable: it is a genuine **signedness observation** in an outgoing-path
length computation that the kernel's type-checked `min()` macro flags (the gcc unit build
does not error on it). It is worth a look independent of fuzzing.

**Next step:** the three files need clang-compat shims for x86 per-cpu/preempt and the
module-version symbol (a small `fuzz_compat.h` force-included before the kernel headers).
Once they compile, the Focus A/B harnesses link and the per-type parsers become fuzzable
with coverage. This is the single remaining piece of the fuzzing plan.

## Assets

- Harnesses: `nix/fuzz/harness/` (`fuzz_dissector.cc`, `deser/*.cc`, `roundtrip/*.cc`, `fuzz_selftest.cc`, `mock_harness.h`, `homa_wire_spec.h`, `fuzz_guard.h`)
- Dictionary: `nix/fuzz/dict/homa_wire.dict` (packet-type bytes + boundary offsets)
- Seed corpus: `nix/fuzz/corpus-seeds/<type>/` (one structurally-valid packet per type)
- Deeper run available: `nix build .#fuzz-deep` (fork mode + dictionary + crash dedup by ASan signature)
