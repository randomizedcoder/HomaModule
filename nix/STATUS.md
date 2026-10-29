# Homa Nix testing: findings and follow-ups

What the flake's builds, tests, analysis and microVM runs have shown about Homa, and what is
worth looking into next.

Related docs:
- **Per-target build status:** [`docs/STATUS.md`](docs/STATUS.md)
- **Upstream PRs and their outcomes:** [`../analysis-reports/pr-tracker.md`](../analysis-reports/pr-tracker.md)
- **VM pair test plan:** [`microvms/PLAN-pairs.md`](microvms/PLAN-pairs.md)

| | |
|---|---|
| **Last update** | 2026-10-28 |
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
| KASAN VM | `homa-microvm-test-debug` | ⏳ not run yet (F7) |
| Static analysis | `analysis-deep` | Four rounds triaged; see the bugs below |

### cp_node over the VM link (workload w4, 0.2 Gb/s target, 6 s)

| Server ↔ client | Homa Kops/s | Homa RTT P50 / P99 (µs) | TCP Kops/s | TCP RTT P50 / P99 (µs) |
|---|---|---|---|---|
| 6.12 ↔ 6.12 | 0.25 | 4777 / 20700 | 0.15 | 251 / 42143 |
| 6.12 ↔ 7.3 | 0.24 | 2927 / 19004 | 0.12 | 274 / 42638 |
| 7.3 ↔ 6.12 | 0.23 | 4780 / 21209 | 0.16 | 329 / 42130 |
| 7.3 ↔ 7.3 | 0.18 | 5024 / 23464 | 0.13 | 343 / 42682 |

These are functional numbers: an emulated link (QEMU socket, about 1–2 Gb/s) between VMs that
share host CPUs. They show that traffic flows, not how fast Homa is. Even so, the P50 gap is
large enough to look into (F2).

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

### F2: Homa's median RTT is 11–16× TCP's over the VM link

In every pairing, Homa's cp_node P50 is about 3–5 ms against about 0.3 ms for TCP. Homa's P99
is about half of TCP's. All RPCs complete, and dmesg is clean.

- **Not the cause:** the Homa qdisc isn't attached in these tests, so round-4 candidate 5
  (`SPEED_UNKNOWN` from virtio-net in `homa_qdev_update_sysctl`) doesn't apply here.
- **Leading suspect:** Homa assumes a 25 Gb/s link (`homa->link_mbps = 25000`,
  `homa_utils.c:32`), but the link carries about 1–2 Gb/s. Homa sizes its unscheduled bytes
  and grants for the faster link, so packets may pile up in the virtio/QEMU queues. That
  would explain a high median with a tolerable tail.
- **Other candidates:** timer-driven retransmission (RESENDs), the bursty w4 size mix, or
  QEMU socket buffering.
- **Experiments (cheap, in the pair test):**
  1. Set `net.homa.link_mbps` to 1000–2000 on both nodes, and re-measure.
  2. Diff `/proc/net/homa_metrics` before and after the cp_node run, looking at
     `resent_packets`, `packets_sent_RESEND` and the grant counters.
  3. Repeat with workload `w1` (small messages) to separate per-packet latency from
     queueing.
  4. If it is still unexplained, take a timetrace (`tthoma.py`) of one slow RPC.
- **Why it matters:** if (1) fixes it, it's a configuration note for VM users. If not, it may
  be a real Homa latency bug, which would be worth an upstream report.

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
| 1 | F2 experiments: `link_mbps`, metric deltas, `w1`, timetrace | Explain Homa's RTT gap; a possible real bug | small (pair-test variants) | us |
| 2 | PLAN-pairs phase 3: `homa-vm-matrix` summary runner | One-command demo; would also have caught F2 at a glance | small | us |
| 3 | PLAN-pairs phase 4: netem loss and delay | Test RESEND and timeout paths across a real link (F3) | small | us |
| 4 | PLAN-pairs phase 5: Homa qdisc on virtio | Should reproduce round-4 candidate 5 in a real kernel; exercises the pacer | medium | us |
| 5 | Run `homa-microvm-test-debug`, then a KASAN pair test | Memory-safety coverage of the real data path | medium (kernel build) | us |
| 6 | IPv6 pair test (`--ipv6` for cp_node, v6 addresses on eth1) | #137/#138 were IPv6 bugs; nothing tests v6 between nodes | small | us |
| 7 | Round-4 candidates 5–8, test-first | More upstream fixes in John's style | medium | us → upstream |
| 8 | Which LTS will `main` target? | Decides F1 and the unit KDIR (F5) | — | ask John (#120) |
| 9 | Restore the `homa_drop_packet` call, or drop its sysctls? | F3 | — | ask John |
| 10 | Post the F2 result upstream if it turns out to be Homa, not the VM | Real-world latency issue | — | after #1 |
| 11 | Bootable 7.0–7.2 kernels (PLAN-pairs phase 6) | Full VM coverage of the 7.x series | large (kernel builds) | optional |
