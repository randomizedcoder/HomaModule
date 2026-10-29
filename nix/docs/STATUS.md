# Homa Nix Flake — Build Status

> Living progress tracker. See [`DESIGN.md`](DESIGN.md) for architecture and
> [`../README.md`](../README.md) for the command cheat-sheet.

| | |
|---|---|
| **Branch** | `nix-flake` (rebased on upstream `main` = `4bd0275`) |
| **Current phase** | Round 2 done; flake targets 7.x with per-kernel builds and microVMs |
| **Last update** | 2026-10-28 |
| **nixpkgs** | `nixos-unstable` |
| **Default kernel** | `linuxPackages_latest` (7.3); unit harness and fuzz-mock on 6.18.57 |

## Key outcome — 7.x
- Upstream `main` builds on 7.1+ since our port (#120) landed as `e65a5c0`, with John's
  rework. `nix/patches/` is empty again. Upstream PR status: `analysis-reports/pr-tracker.md`.
- `homa.ko` builds on 6.12 and 7.0–7.3 and on a local 7.3-rc7 checkout.
  **It loads and passes echo RPCs (100 B–1 MB) in microVMs on 7.3.0 and 6.12.113**, both over
  loopback (recvmsg path) and across netns over veth with GRO and the RPS flow table on
  (7.3: 1728 `homa_gro_receive`, 475 `homa_set_softirq_cpu` calls, so the `rps_tag_ptr` code runs).
- 6.18.57 still fails (recvmsg/bind backports to 6.18 stable; deferred, see
  `analysis-reports/round2/candidates.md`). 6.1 and 6.6 predate `net/rps.h` and are below
  Homa's supported range; they stay in the matrix as a record.

## Build matrix (`nix build .#homa-build-matrix`, patched source)
| Kernel | Source | Result |
|---|---|---|
| 6.1.190 | nixpkgs | ❌ no `net/rps.h` (unsupported) |
| 6.6.159 | nixpkgs | ❌ no `net/rps.h` (unsupported) |
| 6.12.113 | nixpkgs | ✅ |
| 6.18.57 | nixpkgs | ❌ 6.18 stable backports (deferred) |
| 7.0.14 | kernel.org | ✅ compile |
| 7.1.13 | kernel.org | ✅ compile |
| 7.2.12 | kernel.org | ✅ compile |
| 7.3 | nixpkgs | ✅ |
| 7.3-rc7 (`af32da41b032`) | local, `HOMA_LINUX_SRC` | ✅ compile |

## What builds (verified `nix build`)
| Target | Status |
|---|---|
| `nix flake show` (all outputs) | ✅ evaluates |
| `homa-module` (7.3) | ✅ |
| `homa-module-<series>` | see matrix above |
| `homa-utils` | ✅ |
| `homa-tests` | ✅ builds and passes (hermetic 6.18 unit KDIR) |
| `analysis-quick` | ✅ |
| `analysis-sparse` / `-smatch` / `-compile-db` (7.3) | ✅ sparse 1586 raw (980 on 6.18), smatch 38 |
| `fuzz`, `fuzz-run`, `fuzz-cov` | ✅ standalone decoder harnesses |
| `fuzz-selftest` | ✅ PASS (canary catches injected overflow) |
| `fuzz-mock` | ✅ 10 real-code harnesses through `homa_softirq`; smoke gate vs `nix/fuzz/known-findings.txt` |
| `homa-microvm-test` (7.3.0) | ✅ PASS: insmod, echo RPCs ×6 (loopback, then veth+GRO+RPS), rmmod, clean dmesg |
| `homa-microvm-test-6_12` | ✅ PASS |
| `homa-microvm-test-debug` (KASAN) | ⏳ not run (rebuilds the kernel) |
| `homa-pair-test` (7.3 ↔ 7.3) | ✅ PASS: ping, echo ×6 across VMs, cp_node w4 Homa + TCP, rmmod, clean dmesg on both |
| `homa-pair-test-<server>-<client>` | ✅ PASS for 6_12-6_12, 6_12-7_3, 7_3-6_12, 7_3-7_3; all four run in parallel in 50 s |

## Phase checklist
- [x] **Phase 0 — Branch.** `nix-flake`.
- [x] **Phase 1 — Design doc + status tracker.**
- [x] **Phase 2 — Flake skeleton + foundation** (`flake.nix`, `README.md`, `kernel/packages/env-vars`).
- [x] **Phase 3 — Module + userspace derivations.** module ✅; userspace: utils ✅, tests ❌ (drift).
- [x] **Phase 4 — Dev shell** (`devshell.nix` + `shell-functions/`).
- [x] **Phase 5 — microVM** (`microvms/*`) — per-kernel guests; in-guest smoke test passes on 7.3 and 6.12.
  Pair tests (two VMs over a QEMU socket link) pass for every 6.12/7.3 pairing; see
  `microvms/PLAN-pairs.md`.
- [x] **Phase 6 — OCI image** (`oci.nix`) ✅.
- [x] **Phase 7 — Static analysis** (`analysis/*`) — quick ✅, cppcheck ✅, clang-tidy ✅ (2130), sparse ✅.
- [x] **Phase 8 — Fuzzing** (`fuzz/*`) — Focus C + selftest + cov ✅; Focus A/B best-effort (3 TUs to unblock).
- [x] **Phase 9 — flake.nix usage header** ✅ (mirrored in `README.md`).
- [x] **Phase 10 — Reports** — `analysis-reports/round1/` ✅.
- [x] **Round 2** — rebase on main, 6.18 default, hermetic unit KDIR, real-code fuzz-mock, `analysis-reports/round2/` ✅.
- [x] **7.x** — default 7.3, `nix/patches/`, `kernel-src.nix` (7.0–7.2 + local), `homa-build-matrix`, per-kernel microVMs ✅.

## Open follow-ups
1. **fuzz-mock:** remove entries from `nix/fuzz/known-findings.txt` as upstream fixes land
   (the only one, `homa_incoming.c:63`, went with #121; the list is empty).
2. ~~**nix/patches:** delete the 7.1 patch once upstream carries it~~ (done 2026-10-28).
3. **6.18.57:** goes green once a 6.18-stable compat fix lands (recvmsg 6.18.40, bind 6.18.57).
4. **Debug microVM:** run `homa-microvm-test-debug` (KASAN kernel build, ~30 min).
5. **Unit harness on 7.x:** `test/mock.c` against 7.3 headers, so `homa-tests`/fuzz-mock can
   follow the default kernel.
