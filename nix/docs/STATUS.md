# Homa Nix Flake — Build Status

> Living progress tracker. See [`DESIGN.md`](DESIGN.md) for architecture and
> [`../README.md`](../README.md) for the command cheat-sheet.

| | |
|---|---|
| **Branch** | `nix-flake` (rebased on upstream `main` = `ae45ada`) |
| **Current phase** | Round 2 — analysis + real-code fuzzing done; candidates in `analysis-reports/round2/` |
| **Last update** | 2026-10-21 |
| **nixpkgs** | `nixos-unstable` |
| **Default kernel** | `linuxPackages_6_18` (6.18.57 LTS) |

## Key outcome — kernel selection
- 6.18.40+ backported the recvmsg `addr_len` removal and 6.18.57 the `sockaddr_unsized`
  bind change. Homa's version gates key off 6.19 and 7.1, so **`homa.ko` from `main` does
  not build on 6.18.57** until the round-2 compat fix lands
  (see `analysis-reports/round2/static-analysis-report.md`).
- 6.12.x LTS and 6.19.x build. 7.2.x fails in `homa_offload.c` (RPS API); that's a
  separate 7.x port.
- The unit tests and fuzz-mock don't need a building module: they use the hermetic
  `nix/unit-kdir` (6.18.57 headers + `homa_unit_compat.h`).

## What builds (verified `nix build`)
| Target | Status |
|---|---|
| `nix flake show` (all outputs) | ✅ evaluates |
| `homa-module` (6.18.57) | ❌ upstream recvmsg/bind break (fix is round-2 candidate 1) |
| `homa-module-6_12` | ✅ |
| `homa-module-latest` (7.2.x) | ❌ expected drift (`homa_offload.c` RPS) |
| `homa-utils` | ✅ |
| `homa-tests` | ✅ builds and passes (hermetic 6.18 unit KDIR) |
| `analysis-deep` | ✅ ruff 1973 / shell 4 / clang-format 35 / cppcheck 16 / clang-tidy 1210* / sparse 333* / smatch 16* |
| `fuzz`, `fuzz-run`, `fuzz-cov` | ✅ standalone decoder harnesses |
| `fuzz-selftest` | ✅ PASS (canary catches injected overflow) |
| `fuzz-mock` | ✅ 10 real-code harnesses through `homa_softirq`; smoke gate vs `nix/fuzz/known-findings.txt` |
| `homa-microvm*` | ⏳ evaluates; boot not yet run here |

\* Truncated by the 6.18.57 build break. On the compat-fixed tree: clang-tidy 2202, sparse 980, smatch 38.

## Phase checklist
- [x] **Phase 0 — Branch.** `nix-flake`.
- [x] **Phase 1 — Design doc + status tracker.**
- [x] **Phase 2 — Flake skeleton + foundation** (`flake.nix`, `README.md`, `kernel/packages/env-vars`).
- [x] **Phase 3 — Module + userspace derivations.** module ✅; userspace: utils ✅, tests ❌ (drift).
- [x] **Phase 4 — Dev shell** (`devshell.nix` + `shell-functions/`).
- [x] **Phase 5 — microVM** (`microvms/*`) — implemented + evaluates; boot not yet run here.
- [x] **Phase 6 — OCI image** (`oci.nix`) ✅.
- [x] **Phase 7 — Static analysis** (`analysis/*`) — quick ✅, cppcheck ✅, clang-tidy ✅ (2130), sparse ✅.
- [x] **Phase 8 — Fuzzing** (`fuzz/*`) — Focus C + selftest + cov ✅; Focus A/B best-effort (3 TUs to unblock).
- [x] **Phase 9 — flake.nix usage header** ✅ (mirrored in `README.md`).
- [x] **Phase 10 — Reports** — `analysis-reports/round1/` ✅.
- [x] **Round 2** — rebase on main, 6.18 default, hermetic unit KDIR, real-code fuzz-mock, `analysis-reports/round2/` ✅.

## Open follow-ups
1. **fuzz-mock:** ✅ done in round 2 (`nix/fuzz/harness/mock/`, `build-mock-fuzzers.sh`).
   Remove entries from `nix/fuzz/known-findings.txt` as upstream fixes land.
2. **homa-microvm boot:** exercise `nix run .#homa-microvm-test` on a KVM-capable host
   (builds the guest + boots QEMU).
3. **homa-module on 6.18.57:** goes green once the 6.18 LTS compat fix lands upstream.
4. **7.x:** revisit after the upstream 7.x porting series (PR #110) is applied.
