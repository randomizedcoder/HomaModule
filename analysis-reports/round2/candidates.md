# Round 2 — PR candidates

Triage rules (from round-1 feedback): a candidate must be a reachable bug or real UB,
must not already be fixed or in flight upstream, and must not be an API-contract
guard. Add a test only when behaviour observably changes, in `TEST_F` style placed
next to the code's existing tests.

Round 2 produced **two** candidates that meet the bar. Everything else from static
analysis and fuzzing is a false positive, a duplicate of open PR #111, or style churn
(see the two reports).

## 1. Build on 6.18 LTS (≥ 6.18.40 / ≥ 6.18.57)

- **What:** Homa's gates for the recvmsg `addr_len` removal (7.1) and
  `sockaddr_unsized` (6.19) miss the 6.18 stable backports (6.18.40 and 6.18.57).
  `main` fails to build on current 6.18 LTS.
- **Fix:**
  - `homa_impl.h`: `SOCKADDR` is `sockaddr_unsized` from 6.18.57. Define
    `HOMA_RECVMSG_NO_ADDR_LEN` for ≥ 7.1 and for 6.18.40 ≤ v < 6.19.
  - `homa_plumbing.c`: under that macro, `proto.recvmsg` points at a small adapter
    that calls `homa_recvmsg(..., &addr_len)` and sets `msg->msg_namelen`, which is
    what `sock_common_recvmsg` did before the change.
  - `homa_recvmsg()` and its ~20 unit-test call sites are untouched.
- **Verified:** build matrix 6.12 / 6.18.22 / 6.18.55 / 6.18.57 / 6.19.9 all OK.
- **Test:** none. It's a compile-time change, and the unit harness builds against
  the 6.17.8 / 7.0.14 objects, where the adapter isn't compiled.
- **Commit subject:** "Build on 6.18 LTS kernels with backported recvmsg/bind changes"

## 2. Reject zero-length incoming messages

- **What:** `homa_message_in_init()` accepts `length == 0`, then indexes
  `small_msg_bytes[(length - 1) >> 6]`, which is `[-1]` and lands before the
  per-CPU metrics struct. A peer can trigger this with a DATA or START_MSG whose
  `msg_length` is 0 (new server RPC via `homa_rpc_alloc_server`, or a client
  response via `homa_data_pkt`). Homa's own sender can never produce such a
  message: `homa_sendmsg()` rejects zero length.
- **Found by:** `fuzz_data_pkt` / `fuzz_start_msg_pkt` (UBSan index -1).
- **Fix:** `if (length == 0 || (unsigned int)length > HOMA_MAX_MESSAGE_LENGTH) return -EINVAL;`
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
