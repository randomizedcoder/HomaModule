# Homa Nix flake: status, findings and follow-ups

The single status doc for the flake: what builds and passes on each kernel, what the builds,
tests, analysis and microVM runs have shown about Homa, and what to look into next.

Related docs:
- **Commands and quick start:** [`README.md`](README.md)
- **Architecture and rationale:** [`docs/DESIGN.md`](docs/DESIGN.md)
- **Upstream PRs and their outcomes:** [`../analysis-reports/pr-tracker.md`](../analysis-reports/pr-tracker.md)
- **VM pair test plan:** [`microvms/PLAN-pairs.md`](microvms/PLAN-pairs.md)

| | |
|---|---|
| **Last update** | 2026-10-28 |
| **Branch** | `nix-flake` on randomizedcoder/HomaModule, rebased on upstream `main` |
| **nixpkgs** | `nixos-unstable` |
| **Default kernel** | `linuxPackages_latest` (7.3); unit harness and fuzz-mock use 6.18.57 headers (F5) |
| **Upstream base** | `main` = `4bd0275` ("Get 'make `__STRIP__`=1' working again") |
| **Kernels** | nixpkgs 6.1.190, 6.6.159, 6.12.113, 6.18.57, 7.3.0; kernel.org 7.0.14, 7.1.13, 7.2.12 |

---

## Results at a glance

| Area | Command | Result on `main` |
|---|---|---|
| Module build | `nix build .#homa-build-matrix` | ✅ 6.12, 7.0, 7.1, 7.2, 7.3. ❌ 6.18.57 (F1). ❌ 6.1/6.6 (no `net/rps.h`, below Homa's range) |
| Stripped build | `make __STRIP__=1` (7.3) | ✅ clean |
| Unit tests | `nix build .#homa-tests` | ✅ 884/884, in IPv6 and `--ipv4` modes |
| Fuzzing, real parsers | `nix build .#fuzz-mock` | ✅ all 10 harnesses run clean; the known-findings list is empty |
| Fuzzing, wire decoder | `fuzz-run`, `fuzz-selftest` | ✅ selftest canary PASS |
| Single VM | `homa-microvm-test-{6_12,7_3}` | ✅ insmod, loopback echo, netns/veth with GRO+RPS (about 1.7k `homa_gro_receive` and 460 `homa_set_softirq_cpu` calls), rmmod, clean dmesg |
| Two VMs | `homa-pair-test-<server>-<client>` | ✅ all four 6.12/7.3 pairings: ping, echo 100 B–1 MB, cp_node w4 over Homa and over TCP, clean dmesg on both. 8 VMs in parallel finish in 50 s |
| Latency sweep | `homa-pair-exp`, `homa-pair-exp-socket` | ✅ F2 explained: QEMU's TCP `socket` link stalls packets; over the UDP `dgram` link (now the default) Homa's P50 matches TCP's |
| KASAN VM | `homa-microvm-test-debug` | ⏳ not run yet (F7) |
| Static analysis | `analysis-deep` | Four rounds triaged; see the bugs below |

### cp_node over the VM link (workload w4, 0.2 Gb/s target, 6 s)

UDP `dgram` link (the default since F2). All five pair targets ran at once (10 VMs), so the
medians are higher than the single-pair sweep in F2.

| Server ↔ client | Homa Kops/s | Homa RTT P50 / P99 (µs) | TCP Kops/s | TCP RTT P50 / P99 (µs) |
|---|---|---|---|---|
| 6.12 ↔ 6.12 | 0.42 | 294 / 31213 | 0.41 | 569 / 22088 |
| 6.12 ↔ 7.3 | 0.35 | 452 / 34976 | 0.41 | 378 / 23300 |
| 7.3 ↔ 6.12 | 0.37 | 490 / 31825 | 0.42 | 318 / 22345 |
| 7.3 ↔ 7.3 | 0.38 | 452 / 34574 | 0.42 | 383 / 20973 |

On the earlier TCP `socket` link, Homa's P50 was 2927–5024 µs and TCP's P99 about 42 ms (F2).

These are functional numbers: an emulated link between VMs that share host CPUs. They show
that traffic flows, not how fast Homa is.

### Build matrix (`nix build .#homa-build-matrix`)

| Kernel | Source | Result |
|---|---|---|
| 6.1.190 | nixpkgs | ❌ no `net/rps.h` (below Homa's supported range) |
| 6.6.159 | nixpkgs | ❌ no `net/rps.h` (below Homa's supported range) |
| 6.12.113 | nixpkgs | ✅ |
| 6.18.57 | nixpkgs | ❌ 6.18-stable backports (F1) |
| 7.0.14 | kernel.org | ✅ compile |
| 7.1.13 | kernel.org | ✅ compile |
| 7.2.12 | kernel.org | ✅ compile |
| 7.3 | nixpkgs | ✅ |
| 7.3-rc7 (`af32da41b032`) | local, `HOMA_LINUX_SRC` | ✅ compile |

### Per target (verified with `nix build` / `nix run`)

| Target | Status |
|---|---|
| `nix flake show`, `nix flake check` | ✅ evaluates, checks pass |
| `homa-module` (7.3), `homa-module-<series>` | ✅ (see the matrix above) |
| `homa-utils`, `homa-utils-debug` | ✅ |
| `homa-tests` | ✅ 884/884 (hermetic 6.18 unit KDIR) |
| `homa-image[-debug]` | ✅ |
| `analysis-quick` | ✅ |
| `analysis-sparse` / `-smatch` / `-compile-db` (7.3) | ✅ sparse 1586 raw (980 on 6.18), smatch 38 |
| `fuzz`, `fuzz-run`, `fuzz-cov` | ✅ standalone decoder harnesses |
| `fuzz-selftest` | ✅ PASS (the canary catches an injected overflow) |
| `fuzz-mock` | ✅ 10 real-code harnesses through `homa_softirq`; gated on `nix/fuzz/known-findings.txt` (empty) |
| `homa-microvm-test` (7.3.0), `homa-microvm-test-6_12` | ✅ PASS |
| `homa-microvm-test-debug` (KASAN) | ⏳ not run (rebuilds the kernel) |
| `homa-pair-test`, `homa-pair-test-<server>-<client>` | ✅ PASS for all four 6.12/7.3 pairings |

---

## Findings

### F1: 6.18-stable backports break the build on 6.18.40 and later

6.18 stable backported two 7.x socket API changes: the recvmsg `addr_len` removal in 6.18.40,
and `sockaddr_unsized` for bind in 6.18.57. Homa's gates (`< KERNEL_VERSION(7, 1, 0)` and
`(7, 0, 0)`) therefore pick the old signatures on 6.18.57. That is a hard error with gcc 15+,
and a `-Wincompatible-pointer-types` warning in the unit build.

- **Status:** raised with John on
  [#120](https://github.com/PlatformLab/HomaModule/pull/120#issuecomment-6486061071). He plans
  to move `main` to the next LTS. If that is 7.3 or later, the problem goes away.
- **Follow-up:** wait for his answer. If 6.18 is the target, send a small gate fix.

### F2: Homa's 5 ms median over the VM link was QEMU's `socket` backend (resolved)

The first pair runs showed Homa's cp_node P50 at about 3–5 ms against about 0.3 ms for TCP,
in every pairing. The sweep target (`nix run .#homa-pair-exp`) runs cp_node once per
experiment, sets `net.homa.*` sysctls on both nodes, and prints the per-node deltas of the Homa
metrics, eth1/virtio/qdisc/softnet drops and TCP retransmits. It found the cause in four runs.

**1. The median is Homa's RESEND timer.** Homa sends a RESEND after `resend_ticks` (default 5)
ticks of 1 ms with nothing received. The P50 tracks that setting, and `link_mbps` does
nothing:

| Run (7.3 ↔ 7.3, `socket` link) | Homa P50 / P99 (µs) | Client RESENDs sent | Server packets resent |
|---|---|---|---|
| w4, defaults | 4717 / 15611 | 2146 | 19467 |
| w4, `link_mbps=1000` | 4837 / 16026 | 2116 | 19403 |
| w4, `link_mbps=2000` | 4873 / 16217 | 2132 | 20252 |
| w4, `resend_ticks=2` | 2028 / 15064 | 2073 | 12512 |
| w4, `resend_ticks=10` | 9577 / 24441 (2580 / 30620 in 1 of 3 runs) | 2379 | 18745 |
| w1 (about 190 B), defaults | 113 / **5067** | 1672 | 2357 |
| TCP w4 / w1 | 225 / 42151, 117 / 41038 | 95 / 6 TCP retransmits | |

**2. Nothing is lost; packets arrive late.** The client's eth1 rx count equals the server's
tx count to within one packet, and the eth1, virtio, qdisc and softnet drop counters all
stay at zero. On w1, the client's `unknown_rpcs` (2326) roughly equals the server's
`resent_packets` (2335). So the original response arrives before its retransmission, and
the late copy finds the RPC already finished. TCP retransmits too, on a link that drops
nothing, and its P99 is about 42 ms.

**3. The UDP `dgram` backend removes the stalls** (`homa-pair-exp`; the old link is
`homa-pair-exp-socket`):

| Run (7.3 ↔ 7.3) | `socket` P50 / P99 (µs) | `dgram` P50 / P99 (µs) | `dgram` Kops/s | `dgram` RESENDs |
|---|---|---|---|---|
| Homa w4, defaults | 4717 / 15611 | 177 / 33386 | 0.45 | 0 |
| Homa w4, `link_mbps=1000` | 4837 / 16026 | 156 / 25195 | 0.36 | 0 |
| TCP w4 | 225 / 42151 | 167 / 24519 | 0.44 | (0 retransmits) |
| Homa w1, defaults | 113 / 5067 | 99 / 166 | 9.78 | 0 |
| TCP w1 | 117 / 41038 | 106 / 225 | 9.02 | (0 retransmits) |

- **Conclusion:** QEMU's `-netdev socket` (a TCP stream between the two QEMU processes) holds
  some packets for milliseconds. Homa recovers through its 5 ms RESEND timer and TCP through
  retransmission, which explains both the 5 ms Homa P50 and the 42 ms TCP P99. Homa behaves
  as designed. It is not a Homa bug, and there is nothing to report upstream. Where in QEMU
  the packets wait has not been investigated.
- **Change:** the pair tests now use `-netdev dgram` (UDP between two host ports) by default.
  It also needs no listen/connect ordering.
- **Still open, minor:** over `dgram`, Homa's w4 P99 (25–33 ms) is close to TCP's (about
  25 ms). Both probably come from the w4 size mix on a slow emulated link, but this hasn't
  been checked.
- **Not the cause:** `link_mbps` (no effect, above), and round-4 candidate 5
  (`SPEED_UNKNOWN`), because the Homa qdisc isn't attached in these tests.

### F3: Homa's built-in packet-drop knobs do nothing

`homa_drop_packet()` (`homa_devel.c:946`) drops bursts of packets as configured by the
`accept_bits` and `drop_bits` sysctls, to exercise retry code. Its only call site is commented
out (`homa_offload.c:259`), so setting the sysctls has no effect.

- **Follow-up:** use `tc netem` for loss tests (PLAN-pairs phase 4). Ask John whether the call
  should come back (it is a development knob) or the sysctls should go.

### F4: Upstream bugs found and fixed

| Round | Source | Sent | Landed | Open |
|---|---|---|---|---|
| 1 | static analysis (cppcheck, clang-tidy, ruff, shellcheck) | 11 | 10 | — (#94 rejected) |
| 2 | fuzz-mock and the 7.x port | 2 | 2 | — |
| 3 | sparse and gcc W=1 | 4 | 4 | — |
| 4 | reading the code (copy-paste asymmetries, error paths) | 4 | — | #137–#140 |

Notable fixes:
- **Fuzzing:** a zero-length incoming message indexed `small_msg_bytes[-1]` (#121).
- **IPv6:**
  - Non-Homa IPv6 TCP was sent to the IPv4 TCP GRO handler (#138).
  - The qdisc bypass hash skipped one word of the IPv6 address, so same-flow TCP packets
    could be reordered (#137).
- **Use-after-free:** the pacer's round-robin pointer was left on a destroyed qdisc (#140).
- **Wrong bit tested:** HOMAIOCINFO's `RPC_PRIVATE` check tested `APP_NEEDS_LOCK` (#139).

Pending candidates: [`round4/candidates.md`](../analysis-reports/round4/candidates.md) items 5–8:
- unknown link speed;
- destroy after a failed init;
- `softirq_cores` bounds;
- the priority map applied twice, which needs re-verifying.

### F5: The test harness lags the default kernel

The unit harness and fuzz-mock build against 6.18.57 headers (`unitKernelPackages`), because
`test/mock.c` is maintained for John's development kernel, not for 7.3. That is fine for
logic tests, but kernel-API drift on 7.x is only caught by the module builds and the VMs.

- **Follow-up:** try `test/mock.c` against 7.3 headers. If the gaps are small, move the unit
  KDIR to follow the default kernel, or to the LTS John picks (F1).

### F6: Small items noted while reading the code

- **`homa_softirq` verbose `pr_warn`:** it reads `h->type` before `h` is set for the current
  skb. It only runs with the verbose sysctl, so at most a one-line fix.
- **`homa_err_handler_v4` and `ICMP_FRAG_NEEDED`:** it treats FRAG_NEEDED as unreachable and
  aborts RPCs, while the v6 handler ignores PKT_TOOBIG. Its `pr_notice` for other ICMP types is
  not rate-limited. This is a policy question for John rather than a PR.

### F7: Coverage gaps in our own testing

- **KASAN/KMEMLEAK VM:** never run. It needs a sanitizer kernel build, about 30 min, cached
  afterwards.
- **Not exercised over a real link yet:** packet loss (netem), the Homa qdisc and pacer,
  IPv6 between VMs, and more than two nodes.
- **7.0–7.2:** compile-checked only; there is no bootable kernel for them in the flake yet.

---

## Follow-up actions

| # | Action | Why | Effort | Who |
|---|---|---|---|---|
| 1 | ~~F2 experiments~~ ✅ done: QEMU `socket` backend stall, pair tests moved to `dgram` | — | — | — |
| 2 | PLAN-pairs phase 3: `homa-vm-matrix` summary runner | One-command demo; would also have caught F2 at a glance | small | us |
| 3 | PLAN-pairs phase 4: netem loss and delay | Test RESEND and timeout paths across a real link (F3) | small | us |
| 4 | PLAN-pairs phase 5: Homa qdisc on virtio | Should reproduce round-4 candidate 5 in a real kernel; exercises the pacer | medium | us |
| 5 | Run `homa-microvm-test-debug`, then a KASAN pair test | Memory-safety coverage of the real data path | medium (kernel build) | us |
| 6 | IPv6 pair test (`--ipv6` for cp_node, v6 addresses on eth1) | #137/#138 were IPv6 bugs; nothing tests v6 between nodes | small | us |
| 7 | Round-4 candidates 5–8, test-first | More upstream fixes in John's style | medium | us → upstream |
| 8 | Which LTS will `main` target? | Decides F1 and the unit KDIR (F5) | — | ask John (#120) |
| 9 | Restore the `homa_drop_packet` call, or drop its sysctls? | F3 | — | ask John |
| 10 | ~~Post F2 upstream~~ not needed: VM link, not Homa | — | — | — |
| 11 | Bootable 7.0–7.2 kernels (PLAN-pairs phase 6) | Full VM coverage of the 7.x series | large (kernel builds) | optional |
| 12 | Keep `nix/fuzz/known-findings.txt` in step with upstream | Entries come out as fixes land, so the fuzz-mock gate stays meaningful; currently empty | ongoing | us |

---

## History

| Date | Milestone |
|---|---|
| 2026-09-18 | Flake built in phases: design doc, module and user-space derivations, dev shell, microVM, OCI image, tiered static analysis, fuzzing. Round 1 reports in `analysis-reports/round1/` |
| 2026-10-21 | Round 2: rebased on `main`, 6.18 default, hermetic unit KDIR, real-code fuzz-mock (found #121), `analysis-reports/round2/` |
| 2026-10-22 | 7.x: default 7.3, `kernel-src.nix` (7.0–7.2 and local trees), `homa-build-matrix`, per-kernel microVMs, GRO/RPS smoke test |
| 2026-10-28 | The 7.1 patch landed upstream (#120), so `nix/patches/` is empty. Two-VM pair tests, cross-kernel pairs, this status doc. F2 latency sweep (`homa-pair-exp`): RESEND-timer stalls from QEMU's `socket` link, pair tests moved to `dgram` |
