# Homa fix/modernization PR tracker

A batch of small, self-contained fixes (each on its own branch, developed test-first)
plus one Python modernization change. Every branch is opened as **two** PRs:

- a **draft PR on the fork** (`randomizedcoder/HomaModule`) that was used for self-review, and
- a **ready-for-review PR upstream** (`PlatformLab/HomaModule`) — the real submission.

Opened upstream on **2026-09-18**. At that time the fork's `main` was identical to
`upstream/main` (tip `d8914b8`), so every branch applied cleanly with no rebase.

## PRs

| Branch | Upstream (PlatformLab) | Fork (draft) | Summary |
|---|---|---|---|
| `fix/tx-pool-max-pool-uninit` | [#94](https://github.com/PlatformLab/HomaModule/pull/94) | [#1](https://github.com/randomizedcoder/HomaModule/pull/1) | Guard `homa_tx_pool_gc()` against an uninitialized `max_pool` deref (NULL + early return). PR also carries the table-driven testing proposal. |
| `fix/tx-pool-min-pages-overflow` | [#95](https://github.com/PlatformLab/HomaModule/pull/95) | [#2](https://github.com/randomizedcoder/HomaModule/pull/2) | Compute the tx page-pool floor in 64-bit to avoid a 32-bit overflow. |
| `fix/tx-pool-void-ptr-arith` | [#96](https://github.com/PlatformLab/HomaModule/pull/96) | [#3](https://github.com/randomizedcoder/HomaModule/pull/3) | Use `u8 *` instead of pointer arithmetic on a `void *` in `homa_copy_iter_to_frags()`. |
| `fix/timer-signed-shift` | [#97](https://github.com/PlatformLab/HomaModule/pull/97) | [#4](https://github.com/randomizedcoder/HomaModule/pull/4) | Make the wrap-around top-bit test shift unsigned (`1U << 31`) to avoid signed-shift UB. |
| `fix/outgoing-frag-signedness` | [#98](https://github.com/PlatformLab/HomaModule/pull/98) | [#5](https://github.com/randomizedcoder/HomaModule/pull/5) | Keep `homa_tx_skb_alloc()` frag-length arithmetic signed. **Defensive/robustness, not a live bug** (values are pre-validated). |
| `fix/grant-offset-validation` | [#99](https://github.com/PlatformLab/HomaModule/pull/99) | [#6](https://github.com/randomizedcoder/HomaModule/pull/6) | Treat the GRANT wire offset as `u32` and clamp **before** storing into the signed `msgout.granted` (`min_t(u32, …)`), so a high-bit offset is capped to length instead of silently dropped. |
| `fix/data-offset-validation` | [#100](https://github.com/PlatformLab/HomaModule/pull/100) | [#7](https://github.com/randomizedcoder/HomaModule/pull/7) | Read DATA `seg.offset` as `u32` in `homa_copy_to_user()`. **Optional hardening** — the original finding was already mitigated before this line. |
| `fix/snprintf-va-end` | [#101](https://github.com/PlatformLab/HomaModule/pull/101) | [#8](https://github.com/randomizedcoder/HomaModule/pull/8) | Close the `va_list` on every path in `homa_snprintf()` (move `va_start` past the early return, add `va_end`). |
| `fix/python-regex-w605` | [#102](https://github.com/PlatformLab/HomaModule/pull/102) | [#9](https://github.com/randomizedcoder/HomaModule/pull/9) | Use raw strings for regex patterns in `util/*.py` (fixes all `W605` invalid-escape warnings). |
| `fix/shell-unquoted-args` | [#103](https://github.com/PlatformLab/HomaModule/pull/103) | [#10](https://github.com/randomizedcoder/HomaModule/pull/10) | Quote ssh arguments in `cloudlab/bin/on_nodes` (`ssh -4 "$node" "$@"`); fixes `SC2068`. |
| `modernize/python-types` | [#104](https://github.com/PlatformLab/HomaModule/pull/104) | [#11](https://github.com/randomizedcoder/HomaModule/pull/11) | Modern type hints (PEP 585/604 + `from __future__ import annotations`) and drop vestigial py2 `__future__` imports across 18 `util/*.py`; also fixes 3 real py2 crashers in `diff_metrics.py`. |

Legend: **#94–#104** = upstream (the ones to watch for merge); **#1–#11** = the fork drafts (self-review copies).

## How each was verified

- **C fixes (#94–#97, #99–#101, #103… )** — built against the nixpkgs Linux 6.12 headers and
  run through the repo's own `test/` kselftest harness (ASan), each with a table-driven
  `TEST_F` showing red-before / green-after. Behavioral where a failure is observable
  (uninit deref, overflow, GRANT high-bit); cppcheck/compiler gate for the portability and
  signedness ones; review + regression for the `va_end` leak (no runtime gate on x86-64).
- **#102 (python W605)** — `ruff --select W605` goes flagged → clean; raw-string conversions
  verified behavior-preserving by tokenizing each file and comparing every string literal.
- **#103 (shell)** — `shellcheck` `SC2068` flagged → clean; a bats scaffold stubs `ssh` and
  asserts argument boundaries (3 cases red before, all green after).
- **#104 (modernization)** — annotations are lazy (`from __future__ import annotations`), so
  zero runtime cost; `ruff UP010` 14 → 0, no legacy typing, `F821` clean, smoke-tested.

## Not-a-live-bug PRs (flagged honestly)

- **#98 / fork #5** — signedness cleanup only; the inputs are already validated. Framed as
  defensive, easy to drop.
- **#100 / fork #7** — defense-in-depth; `homa_add_packet()` already validates and
  `HOMA_MAX_MESSAGE_LENGTH` (1 MB) caps offsets. Framed as optional hardening.

## Testing-approach proposal

Upstream **#94** (fork #1) additionally carries a friendly proposal to adopt **table-driven
tests** using the repo's *own* `kselftest_harness.h` (no new framework): one `TEST_F` with a
`cases[]` table, `TH_LOG` per row, `EXPECT_*` (never `ASSERT_*`) inside the loop. The other
PRs demonstrate the pattern. It's offered for evaluation, not assumed.

## Checking status later

```sh
# All upstream PRs from this effort, with review + CI rollup:
gh pr list --repo PlatformLab/HomaModule --author randomizedcoder \
  --json number,title,state,reviewDecision,statusCheckRollup \
  -q '.[] | "#\(.number) \(.state) review=\(.reviewDecision) \(.title)"'

# One PR in detail (checks, comments, mergeability):
gh pr view <N> --repo PlatformLab/HomaModule --comments

# The fork draft copies:
gh pr list --repo randomizedcoder/HomaModule --state open
```

## Local notes

- Reference bug write-ups live on the `nix-flake` branch under `analysis-reports/bugs/<n>/`
  (not on the fix branches, which carry only the fix + its test).
- The unit harness needs three **uncommitted** local compat shims to build against 6.12
  (`test/mock.c` edits, `test/compat_local.c`, plus build-script overrides). These must
  never be committed. Cleanup when done reviewing:
  `git checkout test/mock.c && rm -f test/compat_local.c test/unit test/*.d`.
