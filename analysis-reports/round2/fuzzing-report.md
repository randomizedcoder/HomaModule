# Homa Fuzzing Report — Round 2

*Companion to [`static-analysis-report.md`](static-analysis-report.md); candidates are in
[`candidates.md`](candidates.md).*

- **Date:** 2026-10-21
- **Upstream base:** `main` = `ae45ada`
- **Reproduce:** `nix build .#fuzz-mock && ./result/bin/run-mock-fuzzers 300 out/`

## What changed since round 1

Round 1 could only fuzz standalone re-implementations of the wire decoders, because
the real-code harnesses wouldn't compile (3 blockers). Round 2 rebuilds
`fuzz-mock` on top of the unit-test mock layer (`test/mock.c`, `test/utils.c`) and the
same hermetic 6.18 KDIR that `homa-tests` uses. The fuzzer drives **Homa's real
receive path**: `homa_softirq` → `homa_dispatch_pkts` → `homa_*_pkt`.

- `fuzz_softirq` takes a scenario byte (none / client OUTGOING / client RCVD_ONE_PKT /
  server RCVD_ONE_PKT / IN_SERVICE / server OUTGOING / both / client RCVD_MSG) and a
  flags byte (aim at the RPC, IPv4/IPv6). Up to 8 fuzzer-controlled packets follow.
- `fuzz_<type>_pkt` is the same harness built with `-DPIN_TYPE=<opcode>`: every packet
  is forced to that type, so the fuzzer spends its time inside one handler.
- Oracles: ASan, UBSan (`-fno-sanitize-recover`), and the mock layer's leak and
  lock-balance checks. Those checks `FAIL()` into `__current_test->passed`, and the
  harness turns that into `abort()`.
- Seeds: `nix/fuzz/tools/gen-mock-seeds.py` produces 20 structurally valid inputs.
  `fuzz_softirq` starts at ~1070 edges.
- Gate: `nix build .#fuzz-mock` runs every harness over the seeds and fails on any
  report not listed in `nix/fuzz/known-findings.txt`. `fuzz-selftest` still PASSES.

## Campaign 1: upstream `main`

10 harnesses × 300 s, `-fork=24`, on a 24-core host (stopped after 7 harnesses once the
pattern was clear).

| Harness | Coverage | Crash files | Signature |
|---|---|---|---|
| fuzz_ack_pkt | 864 | 0 | |
| fuzz_busy_pkt | 845 | 0 | |
| fuzz_cutoffs_pkt | 853 | 0 | |
| fuzz_data_pkt | 979 | 7286 | `homa_incoming.c:63` index -1 (60/60 sampled) |
| fuzz_grant_pkt | 933 | 10698 | `homa_outgoing.c:414` index N into `int[8]` (60/60) |
| fuzz_need_ack_pkt | 923 | 0 | |
| fuzz_resend_pkt | — | 3871 | `homa_outgoing.c:414` (30/30) |

### Finding A (new): zero-length incoming message → `small_msg_bytes[-1]`

`homa_message_in_init()` (`homa_incoming.c:63`):

```c
if (length < HOMA_NUM_SMALL_COUNTS * 64) {
	INC_METRIC(small_msg_bytes[(length - 1) >> 6], length);
```

A DATA or START_MSG packet with `msg_length == 0` gives index -1. Two ways in:
`homa_rpc_alloc_server()` (`homa_rpc.c:185-192`) for a new request, and
`homa_data_pkt()` (`homa_incoming.c:728`) for a response. Only the bounds check
(`(unsigned) length > HOMA_MAX_MESSAGE_LENGTH`) runs first, and it lets 0 through.

`small_msg_bytes` is the first field of `struct homa_metrics`, so index -1 is the 8
bytes *before* the per-CPU metrics object. The write adds `length` (0), which leaves
the value alone, so the practical impact is small. It is still a non-atomic
read-modify-write of memory owned by something else, and it could race with that
owner's own update. It is still UB and is reachable from the
wire. The sender can never produce this message: `homa_sendmsg()` rejects zero-length
messages (`homa_plumbing.c:1227`). So the natural fix is to reject `length == 0` on
receive too.

Not covered by open PR #111.

### Finding B (duplicate): GRANT/RESEND `priority` indexes `priority_map[8]`

`homa_grant_pkt()` and `homa_resend_pkt()` store the wire's u8 `priority` in
`msgout.priority`/`retrans_priority`, and `homa_tx_skb_send()`
(`homa_outgoing.c:414`) then uses it as an index into `homa->priority_map[8]`.
That's an out-of-bounds read from the network. **Already fixed in open PR #111**
(`h->priority >= HOMA_MAX_PRIORITIES` checks plus a unit test), so the fuzzer
independently confirms that PR. No candidate.

## Campaign 2: past the known findings

To get past A and B, a scratch tree (never committed) carries minimal local fixes for
both. The same 10 harnesses ran for 300 s each, seeded with campaign 1's corpora.

| Harness | Coverage (c1 → c2) | Crash files |
|---|---|---|
| fuzz_ack_pkt | 864 → 867 | 0 |
| fuzz_busy_pkt | 845 → 845 | 0 |
| fuzz_cutoffs_pkt | 853 → 853 | 0 |
| fuzz_data_pkt | 979 → 994 | 0 |
| fuzz_grant_pkt | 933 → 935 | 0 |
| fuzz_need_ack_pkt | 923 → 923 | 0 |
| fuzz_resend_pkt | — → 988 | 0 |
| fuzz_rpc_unknown_pkt | — → 915 | 0 |
| fuzz_softirq | — → 1219 | 0 |
| fuzz_start_msg_pkt | — → 1009 | 0 |

**No new findings.** With A and B patched, about 50 minutes of fuzzing through the
real receive path turned up no sanitizer reports, no leaks and no lock imbalances.
Most per-type harnesses reach a coverage plateau within the first minute. The
multi-packet `fuzz_softirq` harness reaches the most code (1219 edges), and longer
runs should target it (`fuzz-deep` style, 30+ minutes).

## Not done this round

- GRO-path harness: PR #111 already reworks GRO validation, so it was skipped to
  avoid duplicate work.
- 7.1+ kernels: Homa doesn't build there (`homa_offload.c` RPS API), see the static
  analysis report.
