# Bug 3 — `homa_snprintf` skips `va_end` on the early return **[M]**

**File:** `homa_devel.c:487`–`:490`
**Severity:** M — `va_list` leak / UB on the early-exit path

## Issue

```c
va_start(ap, format);
if (used >= (size - 1))
	return used;              /* <-- ap never va_end'd */
new_chars = vsnprintf(...);
```

`va_start` must be paired with `va_end` on **every** path. The `used >= size-1` early return
leaks the `va_list` — undefined behavior on ABIs where `va_start` allocates, and a real
resource leak elsewhere. Restructure so a single exit always closes `ap`.

See [`tdd-table.md`](tdd-table.md), [`test_homa_snprintf.c`](test_homa_snprintf.c),
and [`fix.md`](fix.md).
