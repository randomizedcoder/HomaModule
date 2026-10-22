# Bug 9 — TDD table

| # | Category | Scenario | Input line | Expected match |
|---|---|---|---|---|
| 1 | positive | well-formed trace line | `"  12.5 us foo [C3]"` | groups `("12.5", "3")` |
| 2 | negative | missing bracket token | `"  12.5 us foo C3"` | no match (`None`) |
| 3 | boundary | zero core index | `"  0.0 us x [C0]"` | groups `("0.0", "0")` |
| 4 | corner | brackets present but non-numeric core | `"  1.0 us x [CZ]"` | no match |

Run with `python -W error::DeprecationWarning`; today's non-raw literal raises before matching.
