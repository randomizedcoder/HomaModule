# Bug 2 — Fix

Force the multiply to 64-bit before the shift (and, ideally, hoist the expression into the
pure helper `homa_tx_pool_min_pages()` the test drives).

```diff
--- a/homa_tx_pool.c
+++ b/homa_tx_pool.c
@@ homa_tx_pool_gc
-	min_pages = ((homa->tx_page_pool_min_kb * 1000)
-			+ (HOMA_TX_PAGE_SIZE - 1)) >> HOMA_TX_PAGE_SHIFT;
+	min_pages = (((u64)homa->tx_page_pool_min_kb * 1000)
+			+ (HOMA_TX_PAGE_SIZE - 1)) >> HOMA_TX_PAGE_SHIFT;
```

Optional refactor enabling direct unit testing:

```c
int homa_tx_pool_min_pages(struct homa *homa)
{
	return (((u64)homa->tx_page_pool_min_kb * 1000)
			+ (HOMA_TX_PAGE_SIZE - 1)) >> HOMA_TX_PAGE_SHIFT;
}
```
