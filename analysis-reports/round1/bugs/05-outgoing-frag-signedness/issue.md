# Bug 5 — signed/unsigned `min()` in fragment copy **[M]**

**File:** `homa_outgoing.c:294`
**Severity:** M — mixed-signedness `min()`; wrapped-unsigned intermediate

## Issue

```c
int frag_bytes;
frag_bytes = min(skb_frag_size(msg_frag) - bytes_to_skip, bytes_left);
```

`skb_frag_size()` returns `unsigned int`; `bytes_to_skip` and `bytes_left` are `int`. The
subtraction `unsigned - int` is unsigned, and `min()` then compares an `unsigned int` against
`int bytes_left` — kernel `min()` warns/breaks on mismatched signedness, and if
`bytes_to_skip > skb_frag_size()` the unsigned subtraction wraps to a huge value. Make the
operands' types explicit and clamp in a signed domain.

See [`tdd-table.md`](tdd-table.md), [`test_homa_frag_bytes.c`](test_homa_frag_bytes.c),
and [`fix.md`](fix.md).
