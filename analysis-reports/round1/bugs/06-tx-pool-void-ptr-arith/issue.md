# Bug 6 — pointer arithmetic on `void *vaddr` **[L]**

**File:** `homa_tx_pool.c:532`–`:534`
**Severity:** L — non-standard (GNU-only) pointer arithmetic; portability/clarity

## Issue

```c
void *vaddr = kmap_local_page(p);
result = copy_from_iter(vaddr + p_off, p_len, iter);
```

`vaddr + p_off` is arithmetic on a `void *`, a GNU extension (`sizeof(void)==1` assumed), not
standard C — this is what cppcheck flags as `arithOperationsOnVoidPointer`. It compiles under
the kernel's GNU dialect but is non-portable and obscures intent. Use a byte-typed pointer.

See [`tdd-table.md`](tdd-table.md), [`test_homa_pool_copy.c`](test_homa_pool_copy.c),
and [`fix.md`](fix.md).
