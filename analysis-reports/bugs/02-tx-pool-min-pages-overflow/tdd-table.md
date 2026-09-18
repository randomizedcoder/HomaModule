# Bug 2 — TDD table

| # | Category | Scenario | Input `tx_page_pool_min_kb` | Expected `min_pages` |
|---|---|---|---|---|
| 1 | positive | typical config | `1024` | `(1024*1000 + PS-1) >> SHIFT`, positive |
| 2 | boundary | zero | `0` | `0` |
| 3 | boundary | last value that fits int | `2147` | correct positive value, no overflow |
| 4 | negative | overflow threshold | `2147484` | large **positive** page count (never negative) |
| 5 | corner | INT_MAX kb | `INT_MAX` | large positive; `release` never exceeds `release_max` |

The size math is extracted to a small pure helper `homa_tx_pool_min_pages()` so it can be
tested directly. Cases 4–5 return negative today.
