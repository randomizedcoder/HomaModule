# Bug 6 — TDD table

| # | Category | Scenario | Input (`p_off`, `p_len`) | Expected outcome |
|---|---|---|---|---|
| 1 | positive | mid-page offset copy | off=64, len=128 | 128 bytes land at `page+64` |
| 2 | boundary | zero offset | off=0, len=256 | copy starts at page base |
| 3 | boundary | offset to last byte | off=PAGE-1, len=1 | 1 byte at final offset |
| 4 | corner | zero length | off=100, len=0 | no bytes copied; returns 0 |

This is a portability/clarity fix, so the test pins *behavior* (correct destination offset)
that must survive the retype.
