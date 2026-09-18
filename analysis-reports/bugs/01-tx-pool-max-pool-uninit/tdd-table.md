# Bug 1 — TDD table

| # | Category | Scenario | Input (`homa` state) | Expected outcome |
|---|---|---|---|---|
| 1 | positive | one populated pool with low_mark 0 | `max_numa=0`, `tx_pools[0]` valid | returns cleanly; `tx_pages_to_free` collected from that pool |
| 2 | boundary | exactly one pool, low_mark == -1 edge | pool with `low_mark=-1` | returns cleanly; **no NULL deref** (must be guarded) |
| 3 | negative | all pool slots NULL | `max_numa=2`, all `tx_pools[i]=NULL` | returns without touching any pool; **no deref** |
| 4 | corner | multiple pools, pick max low_mark | 3 pools low_mark 1/5/2 | selects the low_mark-5 pool; no deref of others |

Cases 2 and 3 fault (or trip KASAN) against today's code; all four pass after the fix.
