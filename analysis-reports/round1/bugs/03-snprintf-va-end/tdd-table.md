# Bug 3 — TDD table

| # | Category | Scenario | Input (`size`, `used`, fmt) | Expected outcome |
|---|---|---|---|---|
| 1 | positive | normal append | `size=64, used=0, "x=%d",5` | returns 3; buffer `"x=5"` |
| 2 | boundary | buffer exactly full | `size=4, used=3` | returns `used` (3) via early path; `va_end` still called |
| 3 | negative | used past end | `size=4, used=10` | returns `used` (10); no write; `va_end` called |
| 4 | corner | truncating write | `size=8, used=0, "%s","abcdefghij"` | returns `size-1` (7); NUL-terminated |

Rows 2–3 exercise the early return; the `va_list`-leak assertion fails today.
