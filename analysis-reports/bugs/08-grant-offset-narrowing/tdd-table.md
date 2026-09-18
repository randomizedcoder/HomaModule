# Bug 8 — TDD table

| # | Category | Scenario | Input GRANT `offset`, `msgout.granted`, `length` | Expected `msgout.granted` after |
|---|---|---|---|---|
| 1 | positive | advances grant | off=5000, granted=1000, len=10000 | 5000 |
| 2 | negative | stale (<= current) | off=500, granted=1000, len=10000 | 1000 (unchanged) |
| 3 | boundary | grant == length | off=10000, granted=0, len=10000 | 10000 |
| 4 | boundary | grant > length | off=12000, granted=0, len=10000 | 10000 (clamped) |
| 5 | corner | high bit set | off=0x80000000, granted=0, len=10000 | 10000 (clamped, **not** ignored as negative) |

Row 5 yields `0` (grant ignored) today; expected `10000`.
