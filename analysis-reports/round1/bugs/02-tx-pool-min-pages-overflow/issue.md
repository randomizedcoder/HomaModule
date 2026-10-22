# Bug 2 — `tx_page_pool_min_kb * 1000` overflows in `int` **[M]**

**File:** `homa_tx_pool.c:420`; `min_pages` is `int` (`:368`), `tx_page_pool_min_kb` is `int`
(`homa_impl.h`).
**Severity:** M — signed-overflow UB → free-loop overrun

## Issue

```c
min_pages = ((homa->tx_page_pool_min_kb * 1000)
		+ (HOMA_TX_PAGE_SIZE - 1)) >> HOMA_TX_PAGE_SHIFT;
```

The multiply is `int * int` → `int`. `tx_page_pool_min_kb` is a sysctl-settable value; any
setting `>= 2147484` (≈2.1 GB) overflows a 32-bit `int` — signed overflow is UB, and in
practice `min_pages` goes negative, so `release = max_low_mark - min_pages` becomes huge and the
free loop over-runs `tx_pages_to_free`. The size math must be done in a 64-bit type.

See [`tdd-table.md`](tdd-table.md), [`test_homa_tx_pool_min_pages.c`](test_homa_tx_pool_min_pages.c),
and [`fix.md`](fix.md).
