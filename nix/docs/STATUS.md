# Homa Nix Flake — Build Status

> Living progress tracker. See [`DESIGN.md`](DESIGN.md) for architecture and
> [`../README.md`](../README.md) for the command cheat-sheet.

| | |
|---|---|
| **Branch** | `nix-flake` |
| **Current phase** | Phase 10 complete — reports written; follow-ups tracked below |
| **Last update** | 2026-09-18 |
| **nixpkgs** | `nixos-unstable` (evaluates as 26.11) |
| **Default kernel** | `linuxPackages_6_12` (6.12.110) — newest kernel in this nixpkgs that builds Homa |

## Key outcome — kernel selection
- `linux_latest` = **7.2.6**; `homa.ko` does **not** build against it (upstream API drift).
- 6.16 / 6.17 / 6.19 are **EOL-removed** from this nixpkgs (it is 2026).
- **6.12.110 LTS is the newest kernel that builds Homa** → chosen as default.
- `homa-module-latest` kept to reproduce the 7.2.6 drift over time.

## What builds (verified `nix build`)
| Target | Status |
|---|---|
| `nix flake show` (all outputs) | ✅ evaluates |
| `homa-module`, `homa-module-debug` | ✅ `homa.ko` (6.12) |
| `homa-module-6_12` (and `-6_1`,`-6_6` matrix) | ✅ |
| `homa-module-latest` (7.2.6) | ❌ expected drift (documented) |
| `homa-utils` | ✅ util/ tools compile |
| `homa-tests` | ❌ `-Werror` drift vs 6.12 (needs Homa's ~6.17 target) |
| `homa-image` (OCI) | ✅ tar.gz |
| `analysis-quick` | ✅ ruff 2319 / shell 5 / clang-format 35 |
| `analysis-cppcheck` | ✅ 22 findings |
| `analysis-sparse` | ✅ 974 raw (mostly header noise) |
| `analysis-standard` (clang-tidy) | ✅ 2130 findings (best-effort) |
| `fuzz`, `fuzz-run` | ✅ standalone harnesses, 0 crashes |
| `fuzz-cov` | ✅ 100% coverage of the wire decoder |
| `fuzz-selftest` | ✅ PASS (canary catches injected overflow) |
| `fuzz-mock` (Focus A/B real code) | ⚠️ 20/23 TUs compile w/ clang; 3 block (percpu/preempt/min-signedness) |
| `homa-microvm*` | ⏳ not yet built here (heavy: guest+kernel); scaffolding complete + evaluates |

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
- [x] **Phase 10 — Reports** — `analysis-reports/{static-analysis,fuzzing}-report.md` ✅.

## Open follow-ups
1. **fuzz-mock:** add a force-included `fuzz_compat.h` shim for x86 per-cpu/preempt +
   `__modver_version_show`, and resolve the `min()` signedness in `homa_outgoing.c`, to
   unblock the Focus A/B real-code harnesses (3 translation units).
2. **homa-microvm boot:** exercise `nix run .#homa-microvm-test` on a KVM-capable host
   (builds the guest + boots QEMU).
3. **homa-tests / newer kernels:** revisit when nixpkgs carries a non-EOL build of Homa's
   target kernel (~6.17+), or when Homa `main` supports 7.x.
