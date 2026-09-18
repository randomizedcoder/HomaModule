# Bug 8 — deserialized GRANT `offset` narrowed `u32`→`int` **[M]**

**File:** `homa_incoming.c:809`
**Severity:** M — deserialization; large grant silently dropped (flow-control stall)
**Focus:** (de)serialization — primary fuzzing focus area

## Issue

```c
int new_offset = ntohl(h->offset);
```

Same pattern as Bug 7 in the GRANT handler: a wire `__be32` becomes signed `int new_offset`.
A high-bit value becomes negative, and the guard `if (new_offset > rpc->msgout.granted)` then
*silently drops* a legitimately large grant (a flow-control stall) rather than crashing — a
correctness/DoS-shaped defect distinct from Bug 7's copy path. Handle it as unsigned and clamp
to `msgout.length`.

See [`tdd-table.md`](tdd-table.md), [`test_homa_grant_offset.c`](test_homa_grant_offset.c),
and [`fix.md`](fix.md).
