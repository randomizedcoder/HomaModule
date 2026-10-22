# Bug 7 — TDD table

Message length fixed at 10000 for all rows.

| # | Category | Scenario | Input DATA `seg.offset` | Expected outcome |
|---|---|---|---|---|
| 1 | positive | in-range offset | 0 | accepted; copy proceeds |
| 2 | positive | mid-message offset | 5000 | accepted |
| 3 | boundary | last valid offset | 9999 | accepted |
| 4 | negative | offset == msg_len | 10000 | rejected / packet dropped |
| 5 | corner | high bit set (wire) | `0x80000000` | rejected as out-of-range (**not** treated as negative) |
| 6 | corner | max u32 | `0xFFFFFFFF` | rejected |

Rows 5–6 pass today by accident (negative offset mis-handled downstream); the test makes the
required rejection explicit.
