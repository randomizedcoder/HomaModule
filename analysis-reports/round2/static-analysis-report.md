# Homa Static Analysis Report — Round 2

*Companion to [`fuzzing-report.md`](fuzzing-report.md); candidates are in
[`candidates.md`](candidates.md). Round 1 is in [`../round1/`](../round1/).*

- **Date:** 2026-10-21
- **Upstream base:** `main` = `ae45ada` ("Honour gso_force_software again")
- **Kernel:** `linuxPackages_6_18` = **6.18.57 LTS** (flake default)
- **Reproduce:** `nix build .#analysis-deep` (plus the per-tool targets)

## Headline: `main` does not build on current 6.18 LTS

Two networking API changes were backported to the 6.18 stable series after Homa's
version gates were written. Both gates key off 6.19 or 7.1, so 6.18.x builds fail:

| Change | Mainline | Backported to | Homa site |
|---|---|---|---|
| "net: remove addr_len argument of recvmsg() handlers" (8341c989) | 7.1 | **6.18.40** (not 7.0.y, not 6.12.y) | `homa_plumbing.c` `.recvmsg = homa_recvmsg` (x2) |
| "net: Convert proto_ops bind() callbacks to use sockaddr_unsized" | 6.19 | **6.18.57** | `SOCKADDR` in `homa_impl.h` (used by `homa_bind`) |

Sources: kernel.org `ChangeLog-6.18.40` and `ChangeLog-6.18.57` (the 7.0.1–7.0.14
ChangeLogs were checked too, and the recvmsg change is absent from them). Other
out-of-tree modules hit the same break: LINBIT/drbd#156 and nixpkgs#576199.

Build matrix (`make -C $KDIR M=$PWD modules` against every kernel in the store):

| Kernel | `main` | with candidate fix |
|---|---|---|
| 6.12.x LTS | OK | OK |
| 6.18.22 | OK | OK |
| 6.18.55 | **FAIL** (recvmsg) | OK |
| 6.18.57 | **FAIL** (recvmsg, bind) | OK |
| 6.19.9 | OK | OK |
| 7.2.9 | FAIL | FAIL (only `homa_offload.c`, see below) |

The failure also truncated round-2's first sparse/smatch/clang-tidy pass, because
those tools stopped at `homa_plumbing.c`. All numbers below come from the
compat-fixed tree, so every file is covered.

**7.1+ (separate, out of scope).** `homa_offload.c:86-88` uses
`struct rps_sock_flow_table::{mask,ents}`, which 7.1 removed (`rps_tag_ptr`). That
needs a real port and overlaps the 7.x porting series John is applying (PR #110),
so no candidate here.

## Results by tool

| Tool | Round 1 (6.12) | Round 2 (6.18.57) | Notes |
|---|---|---|---|
| ruff (python) | 2319 | 1973 | `util/` tooling; style rules dominate |
| shellcheck/shfmt | 5 | 4 | |
| clang-format | 35 files | 35 files | normalisation only |
| cppcheck | 22 | 16 | see below |
| clang-tidy | 2130 | 2202 | 1401 `misc-include-cleaner`, 366 `casting-through-void` |
| sparse | 974 raw | 980 raw | 38 non-noise in Homa files |
| smatch | n/a | 38 | first round with smatch |

## Triage

Nothing in this round's static analysis is a new reachable bug. In detail:

- **cppcheck `uninitvar`** (`homa_rpc.c:658`, `homa_sock.c:520`,
  `homa_tx_pool.c:461`): false positives. cppcheck can't see through
  `list_for_each_entry*`.
- **smatch `homa_ioc_info()` "rinfo may leak (hole after flags)"**: false positive.
  `homa_rpc_get_info()` starts with `memset(info, 0, sizeof(*info))`
  (`homa_rpc.c:800`).
- **smatch `homa_grant_find_victim()` null `rpc->route`**: the check is a debug
  freeze (`tt_freeze`) instrumentation path, not error handling.
- **smatch `container_of` static assertion** (`homa_sock.c:518`, `neighbour.h`):
  smatch's own type model; gcc and clang accept it.
- **sparse endianness** (`homa_hijack.h:74`, `homa_hijack.c:124`): `ntohs` used where
  `htons` is meant, and a `__sum16`/`__be16` mismatch. Both are numerically
  identical, so they're annotation-only.
- **sparse `homa_ctl_table` not static**: intentional, because
  `test/unit_homa_plumbing.c` declares it `extern`.
- **clang-tidy `sizeof-expression`** (22): all inside `rcu_dereference`,
  `rcu_assign_pointer` or `list_for_each_entry*` expansions.
- **clang-tidy implicit widening** (`homa_incoming.c:686`, `homa_pool.c:77`,
  `homa_qdisc.c:1469`, `homa_tx_pool.c:33`, `homa_plumbing.c:1795`): every operand
  is a small constant or bounded sysctl, so no overflow is possible.
- **`homa_ioc_info()` two-pass RPC array**: the second pass stops at the first
  pass's count (`if (i == num_rpcs) break`), so there is no overflow.
- **gcc 16 `-Wunused-but-set-variable`** (`homa_timer.c:203` `total_rpcs`,
  `homa_qdisc.c:641` `element`, `homa_qdisc.c:1335-1336` `num_updates`/`recovered`):
  *correction (2026-10-28):* these do **not** feed `tt_record*` or metrics. Each is
  written and never read in any configuration, which makes them leftover debugging
  counters. Removing them is style only, and they still warn on upstream `4bd0275`.
- **`homa_devel.c`**: `%u` format mismatch (line 555), non-static
  `snapshot_*`, `__sum16` return. These are in the debug-only file.

## Dedupe

| Item | Status |
|---|---|
| GRANT/RESEND `priority` index into `priority_map[8]` | already in open PR #111 (AlanJAS) |
| GRO packet validation | open PR #111 |
| 6.18 LTS build break | **not** covered upstream |
| `homa_message_in_init()` `length == 0` | **not** covered upstream (see fuzzing report) |
