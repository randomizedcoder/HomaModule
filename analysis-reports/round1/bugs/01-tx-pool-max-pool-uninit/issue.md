# Bug 1 — `max_pool` used possibly-uninitialized in `homa_tx_pool_gc` **[H]**

**File:** `homa_tx_pool.c:369` (decl), `:401`–`:414` (conditional assign), `:419` (first use)
**Severity:** H — memory-safety / wild-pointer dereference

## Issue

`max_pool` is declared uninitialized. It is assigned only inside
`if (pool->low_mark > max_low_mark)` within the scan loop (`:408`–`:411`), and `max_low_mark`
starts at `-1`. If every NUMA pool slot is `NULL` (`homa->tx_pools[i]` all unset — valid before
any pool is populated), or if no pool ever has `low_mark > -1`, the loop never assigns
`max_pool`, and `:419 spin_lock_bh(&max_pool->mutex)` dereferences an indeterminate pointer.
There is no `max_low_mark >= 0` guard before the lock/deref. This is a straight
use-of-uninitialized-value → wild pointer.

```c
int i, max_low_mark, min_pages, release, release_max;
struct homa_tx_pool *max_pool;               /* :369 uninitialized */
...
max_low_mark = -1;
for (i = 0; i <= homa->max_numa; i++) {
	struct homa_tx_pool *pool = homa->tx_pools[i];

	if (!pool)
		continue;                        /* every slot may be NULL */
	spin_lock_bh(&pool->mutex);
	if (pool->low_mark > max_low_mark) {
		max_low_mark = pool->low_mark;
		max_pool = pool;                 /* :410 only path that sets it */
	}
	...
}
spin_lock_bh(&max_pool->mutex);              /* :419 deref of maybe-unset */
```

See [`tdd-table.md`](tdd-table.md) for the test matrix, [`test_homa_tx_pool_gc.c`](test_homa_tx_pool_gc.c)
for the harness code, and [`fix.md`](fix.md) for the change.
