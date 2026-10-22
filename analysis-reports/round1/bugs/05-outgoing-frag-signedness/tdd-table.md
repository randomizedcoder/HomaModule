# Bug 5 — TDD table

| # | Category | Scenario | Input (`frag_size`, `bytes_to_skip`, `bytes_left`) | Expected `frag_bytes` |
|---|---|---|---|---|
| 1 | positive | frag bigger than remaining | 4096, 0, 100 | 100 |
| 2 | positive | remaining bigger than frag | 200, 0, 5000 | 200 |
| 3 | boundary | skip == frag_size | 200, 200, 50 | 0 |
| 4 | corner | skip > frag_size (wrap risk) | 200, 300, 50 | 0 (never a huge/negative value) |
| 5 | boundary | bytes_left == 0 loop guard | 200, 0, 0 | loop body not entered |

`homa_frag_bytes()` extracts the one-line computation as a pure, testable helper.
