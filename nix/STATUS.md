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
| **Last update** | 2026-10-29 |
| **Branch** | `nix-flake` on randomizedcoder/HomaModule, rebased on upstream `main` |
| **nixpkgs** | `nixos-unstable` |
| **Default kernel** | `linuxPackages_latest` (7.3); unit harness and fuzz-mock use 6.18.57 headers (F5) |
| **Upstream base** | `main` = `4bd0275` ("Get 'make `__STRIP__`=1' working again") |
| **Kernels** | nixpkgs 6.1.190, 6.6.159, 6.12.113, 6.18.57, 7.3.0; kernel.org 7.0.14, 7.1.13, 7.2.12 |

---

## Results at a glance

| Area | Command | Result on `main` |
|---|---|---|
| Module build | `nix build .#homa-build-matrix` | ✅ 6.12, 7.0, 7.1, 7.2, 7.3. ❌ 6.18.57 (F1, not a target). ❌ 6.1/6.6 (no `net/rps.h`, below Homa's range) |
| Stripped build | `make __STRIP__=1` (7.3) | ✅ clean |
| Cross compile | `nix build .#homa-cross-matrix` | ✅ `homa.ko` for riscv64 and aarch64 (7.3, normal and stripped). ❌ `util/` is x86-only (F9) |
| Unit tests | `nix build .#homa-tests` | ✅ 884/884, in IPv6 and `--ipv4` modes |
| Fuzzing, real parsers | `nix build .#fuzz-mock` | ✅ all 10 harnesses run clean; the known-findings list is empty |
| Fuzzing, wire decoder | `fuzz-run`, `fuzz-selftest` | ✅ selftest canary PASS |
| Single VM | `homa-microvm-test-{6_12,7_3}` | ✅ insmod, loopback echo, netns/veth with GRO+RPS (about 1.7k `homa_gro_receive` and 460 `homa_set_softirq_cpu` calls), rmmod, clean dmesg |
| Two VMs | `homa-pair-test-<server>-<client>` | ✅ all four 6.12/7.3 pairings: ping, echo 100 B–1 MB, cp_node w4 over Homa and over TCP, clean dmesg on both. 8 VMs in parallel finish in 50 s |
| Latency sweep | `homa-pair-exp`, `homa-pair-exp-socket` | ✅ F2 explained: QEMU's TCP `socket` link stalls packets; over the UDP `dgram` link (now the default) Homa's P50 matches TCP's |
| Lifecycle | `homa-lifecycle-{6_12,7_3}` | ❌ on `main`: phase 3 (smoke) crashes in `homa_route_free` (F8), and phases 7–8 report it. ✅ all 9 phases with the fix, about 22 s |
| Pair lifecycle | `homa-pair-lifecycle-{6_12,7_3}` | ✅ with the F8 and F11 fixes: 39 timed phases, including five `tc netem` phases (delay, 0.1–5 % loss) and Homa's qdisc with its pacer. Echo, cp_node Homa and TCP complete under every one, and Homa recovers by RESEND. Delay alone triggers many resends (F10). On `main`, traffic stalls under Homa's qdisc (F11), and both nodes oops at rmmod (F8) |
| VM matrix | `homa-vm-matrix` | ❌ on `main` (F8, F11). ✅ 10/10 with the fixes (forks #22, #23): smoke, lifecycle and pair lifecycle per kernel, plus four pairs, in 183 s |
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

### Lifecycle test (`nix run .#homa-lifecycle`)

This follows the pcp and xdp2 lifecycle tests. The guest has two consoles on host TCP
ports:

- **ttyS0** is the only kernel console. QEMU logs it to `serial.log` from the first byte,
  so an oops is caught even after the shell has died, during shutdown for instance.
- **hvc0** is a virtio console running a root shell. The host drives each phase through it,
  and it is fast: reading 612 lines of `dmesg` takes 188 ms, where 115200 baud would take
  seconds. Kernel messages never mix into command output.

Results on 7.3 with the F8 fix:

| Phase | | ms |
|---|---|---|
| 1 start | qemu running, ports listening | 108 |
| 2 serial | first kernel line on ttyS0 | 2482 |
| 2b virtio | root shell answering on hvc0 | 12698 |
| 3 smoke | `homa-smoke` over hvc0 | 2722 |
| 4 cycles | 5 × insmod, netns add/del, rmmod | 1025 |
| 5 dmesg | no BUG/Oops/WARNING/KASAN | 188 |
| 6 shutdown | `poweroff` over hvc0 | 2 |
| 7 exit | qemu exits | 3050 |
| 8 serial-log | no oops anywhere in `serial.log` | 8 |

On `main`, phase 3 crashes. Phases 4–6 are then SKIPped (there is no shell), phase 7 reports
"qemu exited before poweroff", and phase 8 shows the oops and its `RIP:` line.

### Pair lifecycle with netem (`nix run .#homa-pair-lifecycle`)

The pair (node0 server, node1 client) driven over both guests' hvc0 consoles, with the same
timed phases as the lifecycle test, plus traffic phases. Each traffic phase runs echo
(`demo_client1`, six RPCs from 100 B to 1 MB), then cp_node w4 over Homa and over TCP for 6 s,
from node1 to node0. It records `homa-node-stats` deltas on both nodes, in
`traffic/<name>/deltas`.

The netem phases put `tc netem` on eth1 of both nodes, so both directions are impaired. Every
netem qdisc has `limit 100000` (packets), enforced by an `assert` in `pair-lifecycle.nix`, so
the queue never overflows and the only drops are the configured random loss, not tail drops.
A phase fails unless:

- echo returns 6/6 and both cp_node runs complete RPCs (they report a P99);
- each node's netem drop rate matches the configured loss (exactly 0 drops at 0 %); and
- with loss, Homa sent RESENDs.

Results on 7.3 with the F8 fix (rates and RTTs from cp_node; drops and resends summed over
both nodes):

| Phase | netem on eth1 (both nodes) | Homa Kops/s, P50 / P99 (µs) | TCP Kops/s, P99 (µs) | netem drops | Homa RESENDs, resent packets | TCP retrans |
|---|---|---|---|---|---|---|
| 7 baseline | none | 0.43, 176 / 27402 | 0.44, 21271 | — | 0, 0 | 0 |
| 8.1 | `delay 1ms` | 0.23, 2217 / 30993 | 0.25, 26340 | 0 % | 225, 15870 | 0 |
| 8.2 | `loss 0.1%` | 0.35, 189 / 34547 | 0.35, 26240 | 0.06–0.07 % | 303, 219 | 244 |
| 8.3 | `loss 1%` | 0.30, 176 / 37735 | 0.12, 204557 | 0.76 % | 2080, 1776 | 1199 |
| 8.4 | `delay 1ms loss 1%` | 0.14, 2223 / 48779 | 0.10, 209001 | 0.74–0.78 % | 1832, 9940 | 508 |
| 8.5 | `loss 5%` | 0.18, 185 / 46154 | 0.01, 553225 | 4.8 % | 6141, 5648 | 463 |
| 9 recovered | removed | 0.45, 186 / 32381 | 0.39, 29206 | — | 0, 0 | 0 |

- **Homa rides out loss better than TCP here.** At 5 % loss, Homa keeps 40 % of its baseline
  rate with P50 unchanged; TCP drops to 2 % with a P99 above half a second. There are no
  `rpc_timeouts` in any phase. 6.12 gives the same picture.
- **netem's measured loss is a little under the configured rate** (0.76 % for 1 %). tc counts
  sent packets per GSO segment but drops per skb, so a dropped GSO skb hides several
  segments. Tail drops would push the measured rate up, which the check bounds at twice the
  configured loss plus 0.5 points.
- **Delay alone makes Homa resend (F10).**

**Homa's qdisc (phases 10–12).** `homa-qdisc on` (`qdisc.nix`) attaches Homa's qdisc to eth1
on both nodes: mq with `homa` on each child, as `cloudlab/bin/config` does, or `homa` as the
root with one tx queue (the case here). Phase 10 runs traffic through it, and TCP must pass
through the qdisc (`qdisc_tcp_packets`). Phase 11 sets `net.homa.link_mbps=1000`, so a 1 MB
echo is several ms of link time and the pacer must defer and send Homa packets
(`pacer_homa_packets`). Phase 12 restores `link_mbps` and the default qdisc.

| Phase | Qdisc | `main` + F8 fix | + F11 fix (fork #23), 7.3 |
|---|---|---|---|
| 10 | `homa`, `link_mbps` 25000 | ❌ echo, Homa and TCP stall: 0 Kops, 1170 RESENDs | ✅ Homa 0.39 Kops, TCP 0.42; TCP through the qdisc 107892 packets |
| 11 | `homa`, `link_mbps` 1000 | ❌ the same; the pacer sends nothing | ✅ Homa 0.36 Kops, TCP 0.39; the pacer sent 145549 Homa packets |

6.12 matches 7.3. Rates are the same as without the qdisc, because the emulated link is far
slower than `link_mbps`.

Times: boot to both shells about 18 s; each traffic phase about 13.6 s; the whole run about
3 min.

### Build matrix (`nix build .#homa-build-matrix`)

| Kernel | Source | Result |
|---|---|---|
| 6.1.190 | nixpkgs | ❌ no `net/rps.h` (below Homa's supported range) |
| 6.6.159 | nixpkgs | ❌ no `net/rps.h` (below Homa's supported range) |
| 6.12.113 | nixpkgs | ✅ |
| 6.18.57 | nixpkgs | ❌ 6.18-stable backports (F1; not a target, LTS will be 7.3+) |
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
| `homa-utils`, `homa-utils-debug` | ✅ (`-debug` links ASan through `NIX_CFLAGS_LINK`; it did not link before 2026-10-30) |
| `homa-module-{riscv64,aarch64}[-strip]` | ✅ compile; `readelf` confirms RISC-V / AArch64 |
| `homa-utils-{riscv64,aarch64}` | ❌ x86-only code in `util/` (F9) |
| `homa-cross-matrix` | ✅ summary of both arches (fails only if a `homa.ko` does) |
| `homa-tests` | ✅ 884/884 (hermetic 6.18 unit KDIR) |
| `homa-image[-debug]` | ✅ |
| `analysis-quick` | ✅ |
| `analysis-sparse` / `-smatch` / `-compile-db` (7.3) | ✅ sparse 1575 raw (980 on 6.18), smatch 38; both fail if kbuild never runs the checker |
| `fuzz`, `fuzz-run`, `fuzz-cov` | ✅ standalone decoder harnesses |
| `fuzz-selftest` | ✅ PASS (the canary catches an injected overflow) |
| `fuzz-mock` | ✅ 10 real-code harnesses through `homa_softirq`; gated on `nix/fuzz/known-findings.txt` (empty) |
| `homa-microvm-test` (7.3.0), `homa-microvm-test-6_12` | ✅ PASS |
| `homa-microvm-test-debug` (KASAN) | ⏳ not run (rebuilds the kernel) |
| `homa-pair-test`, `homa-pair-test-<server>-<client>` | ✅ PASS for all four 6.12/7.3 pairings |
| `homa-lifecycle`, `homa-lifecycle-<series>` | ✅ PASS with the F8 fix (see above) |
| `homa-pair-lifecycle`, `homa-pair-lifecycle-<series>` | ✅ PASS with the F8 fix (see above) |
| `tcl-tests` (check) | ✅ the Tcl drivers: 349/349 tcltest cases on Tcl 8.6 with Expect, the 227 pure ones on Tcl 9.0 (style checks included), nagelfar and tclint clean, oops regex in step with the guests' |

---

## Findings

### F1: 6.18-stable backports break the build on 6.18.40 and later (won't fix)

6.18 stable backported two 7.x socket API changes: the recvmsg `addr_len` removal in 6.18.40,
and `sockaddr_unsized` for bind in 6.18.57. Homa's gates (`< KERNEL_VERSION(7, 1, 0)` and
`(7, 0, 0)`) therefore pick the old signatures on 6.18.57. That is a hard error with gcc 15+,
and a `-Wincompatible-pointer-types` warning in the unit build.

- **Status:** raised with John on
  [#120](https://github.com/PlatformLab/HomaModule/pull/120#issuecomment-6486061071).
  [His answer](https://github.com/PlatformLab/HomaModule/pull/120#issuecomment-6500983772)
  (2026-10-29): the first LTS `main` targets will be 7.3 or later, so Homa doesn't need to
  build on 6.18. No gate fix.
- **Follow-up:** none upstream. 6.18 stays in `homa-build-matrix` as a known failure, so a
  change in the gates shows up there.

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
  (`SPEED_UNKNOWN`), because the Homa qdisc isn't attached in these tests. With it attached,
  candidate 5 stalls traffic outright rather than slowing it (F11).

### F3: Homa's built-in packet-drop knobs do nothing

`homa_drop_packet()` (`homa_devel.c:946`) drops bursts of packets as configured by the
`accept_bits` and `drop_bits` sysctls, to exercise retry code. Its only call site is commented
out (`homa_offload.c:259`), so setting the sysctls has no effect.

- **Follow-up:** loss tests now use `tc netem` (`homa-pair-lifecycle`). Ask John whether the
  call should come back (it is a development knob) or the sysctls should go.

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

- **Follow-up:** `main`'s LTS will be 7.3 or later (F1), so 6.18 headers will soon be the
  odd one out. Try `test/mock.c` against 7.3 headers now, and move the unit KDIR to 7.3 when
  `main` switches.

### F6: Small items noted while reading the code

- **`homa_softirq` verbose `pr_warn`:** it reads `h->type` before `h` is set for the current
  skb. It only runs with the verbose sysctl, so at most a one-line fix.
- **`homa_err_handler_v4` and `ICMP_FRAG_NEEDED`:** it treats FRAG_NEEDED as unreachable and
  aborts RPCs, while the v6 handler ignores PKT_TOOBIG. Its `pr_notice` for other ICMP types is
  not rate-limited. This is a policy question for John rather than a PR.

### F7: Coverage gaps in our own testing

- **KASAN/KMEMLEAK VM:** never run. It needs a sanitizer kernel build, about 30 min, cached
  afterwards.
- **Not exercised over a real link yet:** IPv6 between VMs, and more than two nodes. (Loss,
  delay, and the Homa qdisc and pacer are now covered by `homa-pair-lifecycle`.)
- **7.0–7.2:** compile-checked only; there is no bootable kernel for them in the flake yet.

### F8: Use-after-free in `homa_route_free` on netns exit and rmmod (fix: fork #22)

`homa_peer_free_net()` (the pernet `.exit` path) releases each of the namespace's routes
with `call_rcu(homa_route_free)`. The callback dereferences `route->key.hnet->homa->peertab`.
But `hnet` is pernet data (`.size = sizeof(struct homa_net)`), which the netns core frees
straight after `.exit` and before its own `rcu_barrier()`. It came in with upstream
`8db9f5e` (routes, 2026-10-14).

- **Found by:** the first `homa-vm-matrix` run. One 7.3 smoke VM hit a general protection
  fault in `homa_route_free` (from `rcu_do_batch`) after `ip netns del`. Unloaded VMs rarely
  show it (3 of 8 under load, 0 of 16 alone), because the freed `hnet` usually still holds
  valid pointers.
- **Made deterministic:** the test guests now boot with `init_on_free=1`. Unpatched, every
  smoke run oopses on 6.12 and 7.3 (8/8), and so does every pair client on `rmmod`
  (`unregister_pernet_subsys` frees the init_net `hnet` the same way).
- **Fix:** `rcu_barrier()` at the end of `homa_peer_free_net()`. Unit test
  `homa_peer_free_net__wait_for_rcu_callbacks` is red then green, with 885/885 unit tests
  passing in IPv6 and `--ipv4` modes. The 7.3 build is clean normal and stripped, checkpatch
  is clean, and the VMs go from 8/8 oops to 8/8 pass and the matrix from 0/6 to 6/6.
  Draft:
  [randomizedcoder/HomaModule#22](https://github.com/randomizedcoder/HomaModule/pull/22).
- **Until it lands,** `homa-vm-matrix` and the VM tests fail on `main`, as they should.

### F9: `util/` builds only on x86; `homa.ko` cross-compiles cleanly

`homa-cross-matrix` cross-compiles for riscv64 (`pkgsCross.riscv64`) and aarch64
(`pkgsCross.aarch64-multiplatform`) on an x86_64 host. Toolchains come from the binary cache,
and the 7.3 trees are prepared from source with each arch's nixpkgs kernel config (about
2 minutes each).

- **`homa.ko`:** builds for both arches, in normal and `__STRIP__=1` forms. There are no errors
  and no warnings on riscv64. On aarch64 there is one warning:
  `homa_metrics.c:442: the frame size of 2112 bytes is larger than 2048 bytes`
  (`homa_metrics_print`, which the stripped build leaves out). The same function stays under
  the limit on x86.
- **Bug, riscv clock rate:** in the normal build, `homa_clock()` is `get_cycles()`. On riscv
  that reads the `time` CSR, which ticks at the platform timebase: 10 MHz on QEMU `virt`, and
  1 MHz on some boards. `homa_clock_khz()` (`homa_impl.h:767`) has cases for x86 (`tsc_khz`)
  and arm64 (`arch_timer_get_cntfrq()`), and otherwise returns 1000000, i.e. 1 GHz. So on
  riscv every cycles↔ns conversion is 100× to 1000× off: timeouts, RESEND intervals and
  pacing. A likely fix is `riscv_timebase / 1000` under `CONFIG_RISCV` (the symbol is
  exported GPL, and Homa is Dual BSD/GPL). The stripped (upstream) build uses
  `ktime_get_ns()` and is correct. This was found by reading the code, since nothing runs on
  riscv yet.
- **`util/`:** 0 of 19 programs build on either arch. 17 of 23 sources compile; the other 6 fail
  for two reasons:
  - `rdtsc()` in `util/test_utils.h:63` is x86 inline asm ("impossible constraint in 'asm'").
    It breaks `test_utils.cc`, which every program links, plus `time_trace.cc`, `dist_test.cc`,
    `homa_test.cc` and `smi.cc`. `util/inc_tput.cc:26` has a second, unused copy.
  - The `cp_node.cc:3662` crash handler reads `uc_mcontext.gregs[REG_RIP]`, which is x86_64-only.
- **Follow-up:** ask John whether non-x86 `util/` matters (#14). If it does, the fix is small:
  `__builtin_ia32_rdtsc` on x86 with `clock_gettime(CLOCK_MONOTONIC_RAW)` elsewhere, and
  `REG_RIP` behind `#ifdef __x86_64__`.

### F10: 1 ms of delay with no loss makes Homa resend about a quarter of its data

In `homa-pair-lifecycle` phase 8.1 (`netem delay 1ms` on both nodes, so a 2 ms RTT, no loss),
node1 sent 225 RESENDs in 6 s, and node0 resent 15870 packets: 23 % of its 68855 DATA packets,
about 70 packets per RESEND. Most of them arrived after their RPC had finished: node1 counted
12202 `unknown_rpcs` and 3668 `resent_discards`. 6.12 shows the same (254 RESENDs, 16827
packets). With 1 % loss and no delay, resends match the drops (2080 RESENDs, 1776 packets).

- A receiver requests a resend after `resend_ticks` (5) ticks of 1 ms (`homa_plumbing.c:2180`)
  with nothing heard on an RPC that still expects granted data (`homa_timer.c:155`). A 2 ms
  RTT is well inside 5 ms, so the RTT alone shouldn't trigger it; a grant waits 1 ms each way
  as well.
- **Follow-up (#16):** sweep `resend_ticks` with netem delay (homa-pair-exp style), and look at
  which RPCs request the resends and for what ranges. Then decide whether this is worth asking
  John about. The 2 ms RTT is long for a datacenter, but cross-rack or virtualized paths can
  see it.

### F11: Homa's qdisc stalls all traffic on NICs that report no link speed (fix: fork #23)

Round-4 candidate 5, now reproduced in VMs.
- **Cause:** virtio-net reports `SPEED_UNKNOWN` (-1). `homa_qdev_update_sysctl`
  (`homa_qdisc.c:1404`) takes it as `link_mbps`, so `max_nic_queue_bytes` is negative.
- **Effect:** every packet the qdisc may defer (Homa DATA in messages of 1000 bytes or more,
  and TCP packets of 1000 bytes or more) is deferred, and the pacer never sends it. With
  `homa-qdisc on`, echo, cp_node Homa and TCP all stall (phases 10–11 above).
- **Wider reach:** any NIC whose link is down or whose speed is unknown, and a speed of 0
  would divide by zero.
- **Fix:** keep `homa->link_mbps` unless the speed is valid.
  [randomizedcoder/HomaModule#23](https://github.com/randomizedcoder/HomaModule/pull/23)
  - Test-first: `homa_qdev_update_sysctl__link_speed_unknown` fails on `main` (`link_mbps`
    -1) and passes with the fix.
  - 885/885 in IPv6 and `--ipv4` modes.
  - The pair lifecycle is green on 7.3 and 6.12.

---

## Follow-up actions

| # | Action | Why | Effort | Who |
|---|---|---|---|---|
| 1 | ~~F2 experiments~~ ✅ done: QEMU `socket` backend stall, pair tests moved to `dgram` | — | — | — |
| 2 | ~~PLAN-pairs phase 3: `homa-vm-matrix`~~ ✅ done; its first run found F8 | — | — | — |
| 13 | Send F8 upstream once the user has reviewed fork #22 | Use-after-free on every netns exit and rmmod | — | us → upstream |
| 3 | ~~PLAN-pairs phase 4: netem loss and delay~~ ✅ `homa-pair-lifecycle`; found F10 | — | — | — |
| 16 | F10: why 1 ms of delay triggers resends (sweep `resend_ticks` under netem delay) | A quarter of DATA resent with no loss | small | us, then maybe John |
| 4 | ~~PLAN-pairs phase 5: Homa qdisc on virtio~~ ✅ `homa-pair-lifecycle` phases 10–12; reproduced round-4 candidate 5 (F11), fix fork #23 | — | — | — |
| 17 | Send F11 upstream once the user has reviewed fork #23 | The Homa qdisc stalls all traffic on NICs that report no speed | — | us → upstream |
| 5 | Run `homa-microvm-test-debug`, then a KASAN pair test | Memory-safety coverage of the real data path | medium (kernel build) | us |
| 6 | IPv6 pair test (`--ipv6` for cp_node, v6 addresses on eth1) | #137/#138 were IPv6 bugs; nothing tests v6 between nodes | small | us |
| 7 | Round-4 candidates 6–8, test-first (5 is fork #23) | More upstream fixes in John's style | medium | us → upstream |
| 8 | ~~Which LTS will `main` target?~~ ✅ 7.3 or later (John, #120, 2026-10-29) | Closes F1; unit KDIR moves to 7.3 (F5) | — | — |
| 9 | Restore the `homa_drop_packet` call, or drop its sysctls? | F3 | — | ask John |
| 10 | ~~Post F2 upstream~~ not needed: VM link, not Homa | — | — | — |
| 11 | Bootable 7.0–7.2 kernels (PLAN-pairs phase 6) | Full VM coverage of the 7.x series | large (kernel builds) | optional |
| 14 | Does `util/` need to build off x86? (F9) If so, a portable `rdtsc()` and `REG_RIP` guard | riscv64/aarch64 `util/` builds fail | small | ask John |
| 15 | riscv `homa_clock_khz()`: `riscv_timebase / 1000` (F9) | Timers 100× off on riscv in the normal build | small | us → upstream (if John wants riscv) |
| 12 | Keep `nix/fuzz/known-findings.txt` in step with upstream | Entries come out as fixes land, so the fuzz-mock gate stays meaningful; currently empty | ongoing | us |

---

## History

| Date | Milestone |
|---|---|
| 2026-09-18 | Flake built in phases: design doc, module and user-space derivations, dev shell, microVM, OCI image, tiered static analysis, fuzzing. Round 1 reports in `analysis-reports/round1/` |
| 2026-10-21 | Round 2: rebased on `main`, 6.18 default, hermetic unit KDIR, real-code fuzz-mock (found #121), `analysis-reports/round2/` |
| 2026-10-22 | 7.x: default 7.3, `kernel/src.nix` (7.0–7.2 and local trees), `homa-build-matrix`, per-kernel microVMs, GRO/RPS smoke test |
| 2026-10-28 | The 7.1 patch landed upstream (#120), so `nix/patches/` is empty. Two-VM pair tests, cross-kernel pairs, this status doc. F2 latency sweep (`homa-pair-exp`): RESEND-timer stalls from QEMU's `socket` link, pair tests moved to `dgram` |
| 2026-10-29 | John: `main` will target an LTS of 7.3+ (F1 closed). Phase 3 `homa-vm-matrix`; guests boot with `init_on_free=1`; found F8 (UAF in `homa_route_free`), fix as fork #22. riscv64/aarch64 cross builds (`homa-cross-matrix`, F9). `homa-lifecycle` (pcp-style phases over ttyS0 and hvc0). `homa-pair-lifecycle`: the pair over both consoles, with `tc netem` loss and delay phases (limit 100000); found F10. PLAN-pairs phase 5: Homa's qdisc and pacer in the pair lifecycle; reproduced round-4 candidate 5 (F11), fix as fork #23 |
| 2026-10-30 | Refactor, same targets: the VM drivers in Tcl/Expect with table-driven tcltest suites (`tcl-tests`); flake-parts and one package scope; `homaLib` (source subsets with `lib.fileset`, `mkKbuild`, `perKernel`), `mkAnalysisTool`, one fuzz runner, `ports.nix`; the tree grouped by area, with a README per folder. Fixed on the way: `homa-utils-debug` did not link, and sparse/smatch reported 0 when kbuild could not run |
| 2026-10-30 | Tcl review (Ousterhout-style): a phase script's `return`/`break`/`continue` are recorded and errors keep their stack (`phase-errors.log`); `Batch` restores `HOMA_VM_LOGDIR`; modules `protocol`/`parse`/`report`; `parse netemCheck`, one-pass `delta`; `waitFor`, `Node phase`, a `Pair` class; the echo count from `constants.echoRpcs`; full proc headers checked by `style.test`. The nagelfar gate in `tcl-tests` had never failed (wrong output pattern); fixed. Driver output unchanged |
| 2026-10-30 | Nix workflows for the drivers: `homa-tcl-test` (the suite or part of it: `-file`, `-match`, `--tcl9`) and `homa-tcl-lint`, which the `tcl-tests` check now runs; `homa-vm-compare old new` compares two matrix runs phase by phase (`parse shape`, `report diff`); `nix develop` has Tcl, Expect, tcllib, nagelfar and tclint |
