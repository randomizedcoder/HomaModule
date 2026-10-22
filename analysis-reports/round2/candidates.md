# Round 2 — PR candidates

Triage rules (from round-1 feedback): a candidate must be a reachable bug or real UB,
must not already be fixed or in flight upstream, and must not be an API-contract
guard. Add a test only when behaviour observably changes, in `TEST_F` style placed
next to the code's existing tests.

Round 2 produced **two** candidates that meet the bar. Everything else from static
analysis and fuzzing is a false positive, a duplicate of open PR #111, or style churn
(see the two reports).

## 1. Build on Linux 7.1 and later — fork draft #12

- **What:** Linux 7.1 removed `addr_len` from `proto.recvmsg` (8341c989ac77) and turned
  `net_hotdata.rps_sock_flow_table` into an `rps_tag_ptr` (dd378109d20f). `main` fails on
  7.1, 7.2.9, 7.3-rc6 and 7.3.
- **Fix:**
  - `homa_impl.h`: define `HOMA_RECVMSG_NO_ADDR_LEN` for 7.1 and later.
  - `homa_plumbing.c`: point `proto.recvmsg` at a `homa_recvmsg_proto` adapter that
    behaves like the old `sock_common_recvmsg`.
  - `homa_offload.c`: on 7.1+, `homa_set_softirq_cpu` uses
    `rps_tag_to_table`/`rps_tag_to_mask`.
- **Verified:** builds on 6.12, 6.19.9, 7.2.9, 7.3-rc6 and 7.3, and the unit tests pass.
- **Test:** none (compile-time only).
- **Deferred:** the 6.18 stable backports (recvmsg in 6.18.40, bind in 6.18.57). Gating
  `SOCKADDR` at 6.18.57 breaks `test/mock.c`'s `connect` stubs, because 6.18.57 converted
  `bind` only. It needs a finer gate and is left for a separate change.

## 2. Reject zero-length incoming messages — fork draft #13

- **What:** `homa_message_in_init()` accepts `length == 0`, then indexes
  `small_msg_bytes[(length - 1) >> 6]`, which is `[-1]` and lands before the
  per-CPU metrics struct. A peer can trigger this with a DATA or START_MSG whose
  `msg_length` is 0 (new server RPC via `homa_rpc_alloc_server`, or a client
  response via `homa_data_pkt`). Homa's own sender can never produce such a
  message: `homa_sendmsg()` rejects zero length.
- **Found by:** `fuzz_data_pkt` / `fuzz_start_msg_pkt` (UBSan index -1).
- **Fix:** `if (length == 0 || (unsigned int)length > HOMA_MAX_MESSAGE_LENGTH) return -EINVAL;`
- **Verified:** the test fails before the fix and passes after, the full unit suite passes,
  and 200 saved fuzzer reproducers replay clean.
- **Test:** yes. `homa_message_in_init__zero_message_length` in
  `test/unit_homa_incoming.c`, right after `__negative_message_length`, with the
  same shape: `msg_length = 0`, then `homa_rpc_alloc_server` returns `-EINVAL`.
- **Commit subject:** "Reject zero-length incoming messages in homa_message_in_init"

## Considered and dropped

| Item | Why dropped |
|---|---|
| GRANT/RESEND priority → `priority_map[8]` OOB | Open PR #111 fixes it (fuzzer re-found it) |
| GRO validation | Open PR #111 |
| 7.1+ `homa_offload.c` RPS API | Needs a real port; overlaps PR #110 (7.x series) |
| `homa_hijack.h` `ntohs`/`htons`, `__sum16` | Numerically identical; sparse annotations only |
| `homa_ioc_info` struct-hole leak (smatch) | False positive: `memset` in `homa_rpc_get_info` |
| cppcheck `uninitvar` x3 | False positive (list macros) |
| clang-tidy `sizeof-expression`, widening | Macro expansions or bounded constants |
| gcc 16 unused-but-set vars | Used by `tt_record`/metrics; style |
| `homa_ctl_table` non-static | Deliberate (unit tests use it) |
