# Bug 7 — deserialized DATA `seg.offset` narrowed `u32`→`int`, unvalidated **[M]**

**File:** `homa_incoming.c:398`
**Severity:** M — deserialization; unvalidated wire value becomes negative
**Focus:** (de)serialization — primary fuzzing focus area

## Issue

```c
int offset = ntohl(h->seg.offset);
```

`h->seg.offset` is a wire `__be32`; `ntohl` yields `u32`, assigned to a signed `int`. A
malicious/corrupt peer can send `offset >= 0x80000000`, which becomes **negative**. That
negative offset then flows into copy-out bookkeeping (`start_offset`/`end_offset`,
buffer-position math). Since the value comes straight off the wire in the deserialization
path, it must be validated against the message length before use.

See [`tdd-table.md`](tdd-table.md), [`test_homa_data_offset.c`](test_homa_data_offset.c),
and [`fix.md`](fix.md).
