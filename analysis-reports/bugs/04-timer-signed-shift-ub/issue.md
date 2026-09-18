# Bug 4 — `1 << 31` signed shift is UB in the tick-wrap test **[M]**

**File:** `homa_timer.c:36`–`:37`
**Severity:** M — undefined behavior (signed left shift into the sign bit)

## Issue

```c
if ((rpc->done_timer_ticks + homa->request_ack_ticks - 1 - homa->timer_ticks) & 1 << 31)
```

`1` is `int`; `1 << 31` sets the sign bit of a 32-bit `int`, which is undefined behavior in C.
The intent is "test the high (sign) bit of a `u32` difference for a wrap-safe `>=` comparison."
It happens to work on common compilers but is non-conforming and UBSan-flagged. Use an unsigned
literal and an explicit unsigned difference.

See [`tdd-table.md`](tdd-table.md), [`test_homa_timer_need_ack.c`](test_homa_timer_need_ack.c),
and [`fix.md`](fix.md).
