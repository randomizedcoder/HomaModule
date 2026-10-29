# Upstream PR tracker

Every change sent to [PlatformLab/HomaModule](https://github.com/PlatformLab/HomaModule/pulls?q=is%3Apr+author%3Arandomizedcoder)
from this fork. Each one is reviewed first as a draft PR on
`randomizedcoder/HomaModule`, then opened upstream from the same branch.

John Ousterhout lands PRs by applying our commits to `main` himself, so a landed PR shows as
**CLOSED** on GitHub, not MERGED, and the commit keeps our authorship. Check the
"Upstream commit" column, not the PR state.

**Score: 16 of 17 landed.**

| Round | Sent | Landed | Rejected |
|---|---|---|---|
| 1, static analysis (2026-09-18) | 11 | 10 | 1 (#94) |
| 2, fuzzing + 7.x port (2026-10-21) | 2 | 2 | 0 |
| 3, sparse (2026-10-22) | 4 | 4 | 0 |

## Round 4: hand-found bugs (open)

Opened 2026-10-28. Each was test-first: the new test fails on `main` and passes with the fix.

| Upstream | Fork | Branch | Change |
|---|---|---|---|
| [#137](https://github.com/PlatformLab/HomaModule/pull/137) | #18 | `fix/qdisc-bypass-ipv6-hash` | `homa_qdisc_can_bypass` hashes all four IPv6 words (same-flow TCP could be reordered) |
| [#138](https://github.com/PlatformLab/HomaModule/pull/138) | #19 | `fix/hijack-gro-ipv6-tcp` | Non-Homa IPv6 TCP goes to tcp6 `gro_receive`, not tcp4 |
| [#139](https://github.com/PlatformLab/HomaModule/pull/139) | #20 | `fix/rpc-get-info-private-flag` | `test_bit(RPC_PRIVATE)`, not a mask (it tested `APP_NEEDS_LOCK`) |
| [#140](https://github.com/PlatformLab/HomaModule/pull/140) | #21 | `fix/qdisc-destroy-next-qdisc` | `homa_qdisc_destroy` moves the pacer's `next_qdisc` cursor off the qdisc (use-after-free) |

## Round 3: sparse (`-D__CHECK_ENDIAN__ -Wsparse-all`), W=1

Landed 2026-10-27, unchanged apart from a `Resolves #N` line. None of these has a test,
because none changes behaviour.

| Upstream | Fork | Branch | Upstream commit | Change |
|---|---|---|---|---|
| [#122](https://github.com/PlatformLab/HomaModule/pull/122) | #14 | `fix/hijack-rcu-publish` | `d2d3dc4` | `rcu_assign_pointer` to publish/restore `inet_offloads`/`inet6_offloads[IPPROTO_TCP]` (release ordering; 4 `__rcu` warnings) |
| [#123](https://github.com/PlatformLab/HomaModule/pull/123) | #15 | `fix/hijack-sparse-endian` | `95d5a3b` | `h->urgent == htons(...)`, `__sum16 checksum` in `homa_wire.h` (4 endianness warnings) |
| [#124](https://github.com/PlatformLab/HomaModule/pull/124) | #16 | `fix/plumbing-user-pointers` | `ee5a0a2` | `msg->msg_control_user` and `u64_to_user_ptr` instead of casts (4 `__user` warnings, one `__force` gone) |
| [#125](https://github.com/PlatformLab/HomaModule/pull/125) | #17 | `fix/metric-append-printf` | `bf7dca6` | `__printf(3, 4)` on `homa_metric_append` (gcc W=1 `-Wsuggest-attribute=format`) |

## Round 2: fuzzing and the 7.x port

| Upstream | Fork | Branch | Upstream commit | Change |
|---|---|---|---|---|
| [#120](https://github.com/PlatformLab/HomaModule/pull/120) | #12 | `fix/build-linux-7.1` | `e65a5c0`, then `4e1ebd6` | Build on 7.1+: `homa_recvmsg_proto` adapter (recvmsg lost `addr_len`), `rps_tag_ptr` in `homa_set_softirq_cpu`. **John reworked it** (see below) |
| [#121](https://github.com/PlatformLab/HomaModule/pull/121) | #13 | `fix/reject-zero-length-msgin` | `1d38026` | `homa_message_in_init` rejects `length == 0` (UBSan `small_msg_bytes[-1]`, found by fuzz-mock). Test `homa_message_in_init__zero_message_length` kept |

How John changed #120:
- He took `homa_set_softirq_cpu` from the net-next branch: the same logic, with the full
  comment and a `tt_record3`.
- He dropped `HOMA_RECVMSG_NO_ADDR_LEN`, which can't survive `strip.py`, in favour of plain
  `LINUX_VERSION_CODE` tests.
- `4e1ebd6` then inverted the tests to `< KERNEL_VERSION(7, 1, 0)` so the newest-kernel code
  comes first, which is what the stripper keeps.

On the PR he asked us to check that he hadn't broken anything. The results are in
[Verification of John's #120](#verification-of-johns-120).

## Round 1: static analysis

Landed 2026-09-18 to 09-23. John dropped most of the tests and rewrote #95's.

| Upstream | Fork | Branch | Upstream commit | Outcome |
|---|---|---|---|---|
| [#94](https://github.com/PlatformLab/HomaModule/pull/94) | #1 | `fix/tx-pool-max-pool-uninit` | — | **Rejected.** Guarded a call the API forbids (after `homa_tx_pool_cleanup`). John documented the contract instead (`7d2b451`) |
| [#95](https://github.com/PlatformLab/HomaModule/pull/95) | #2 | `fix/tx-pool-min-pages-overflow` | `1b13cfc` | Landed; John wrote his own 13-line test |
| [#96](https://github.com/PlatformLab/HomaModule/pull/96) | #3 | `fix/tx-pool-void-ptr-arith` | `f806c07` | Merged |
| [#97](https://github.com/PlatformLab/HomaModule/pull/97) | #4 | `fix/timer-signed-shift` | `50d6530` | Landed |
| [#98](https://github.com/PlatformLab/HomaModule/pull/98) | #5 | `fix/outgoing-frag-signedness` | `e91276f` | Merged (robustness only) |
| [#99](https://github.com/PlatformLab/HomaModule/pull/99) | #6 | `fix/grant-offset-validation` | `906d720` | Landed; one short test kept |
| [#100](https://github.com/PlatformLab/HomaModule/pull/100) | #7 | `fix/data-offset-validation` | `e3a5fdf` | Landed, code only (hardening) |
| [#101](https://github.com/PlatformLab/HomaModule/pull/101) | #8 | `fix/snprintf-va-end` | `d258fcb` | Merged |
| [#102](https://github.com/PlatformLab/HomaModule/pull/102) | #9 | `fix/python-regex-w605` | `ef68e6d` | Landed, pytest scaffold dropped |
| [#103](https://github.com/PlatformLab/HomaModule/pull/103) | #10 | `fix/shell-unquoted-args` | `1304e5c` | Landed, bats scaffold dropped |
| [#104](https://github.com/PlatformLab/HomaModule/pull/104) | #11 | `modernize/python-types` | `006bfd3` | Landed; John then annotated `cperf.py`/`tthoma.py` himself |

## What the maintainer wants (from reviewing all three rounds)

1. **Tests:** kselftest `TEST_F(homa_<file>, <function>__<scenario>)` only, placed next to the
   function's existing tests. No tables and no `TH_LOG`. Add a test only when behaviour
   observably changes.
2. **No guards against API misuse.** Fix reachable bugs: network input, sysctl values,
   races, and real UB.
3. **Small, independent commits.** Short imperative subject, a bullet-style body saying
   what, why and how it was found, and no conventional-commit prefix. Send 5–10 per batch.
4. **No Nix upstream.** The flake stays on the fork's `nix-flake` branch.
5. **Code must strip cleanly** (`make __STRIP__=1`, `util/strip.py`). Version gates are
   `#if LINUX_VERSION_CODE < KERNEL_VERSION(...)` with the newest-kernel code first, and
   there are no helper macros like `HOMA_RECVMSG_NO_ADDR_LEN`. CI (#119, #133) now builds
   stripped and runs checkpatch.

## Verification of John's #120

Upstream `main` at `4bd0275`, built with the fork's flake (`nix/patches` is now empty):

| Check | Result |
|---|---|
| `homa-build-matrix` | ✅ 6.12.113, 7.0.14, 7.1.13, 7.2.12, 7.3. ❌ 6.1/6.6 (below supported range), ❌ 6.18.57 (stable backports, below) |
| `homa-tests` (unit, 6.18.57 headers) | ✅ 884 / 884 |
| microVM 7.3.0 | ✅ echo 100 B–1 MB over loopback; netns/veth + GRO + RPS: 1737 `homa_gro_receive`, 470 `homa_set_softirq_cpu` calls (the `rps_tag_ptr` path) |
| microVM 6.12.113 | ✅ same; 1722 / 450 calls (the pre-7.1 path) |

So John's rework is good on both sides of the 7.1 gate.

One gap remains, and it predates #120: 6.18 stable backported both API changes, the
recvmsg `addr_len` removal in 6.18.40 and `sockaddr_unsized` for bind in 6.18.57. Gates
of the form `< KERNEL_VERSION(7, 1, 0)` / `(7, 0, 0)` therefore choose the old signatures
on 6.18.57. That is a hard error for the module (gcc 15+) and a
`-Wincompatible-pointer-types` warning in the unit build. This is worth asking John
about before sending code, since he plans to move `main` to the next LTS.

## Next

Round 4 plan, eight candidates: [`round4/candidates.md`](round4/candidates.md).

## Checking status

```sh
gh pr list -R PlatformLab/HomaModule --author randomizedcoder --state all \
  --json number,state,title -q '.[] | "#\(.number) \(.state) \(.title)"'
# Did it land? Search upstream main for the subject:
git fetch upstream && git log upstream/main --author=randomizedcoder --oneline
```
