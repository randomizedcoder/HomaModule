# Bug 1 — Fix

Initialize the pointer and guard the dereference on a real selection.

```diff
--- a/homa_tx_pool.c
+++ b/homa_tx_pool.c
@@ homa_tx_pool_gc
-	struct homa_tx_pool *max_pool;
+	struct homa_tx_pool *max_pool = NULL;
@@ after the scan loop, before the lock
+	if (!max_pool)		/* no eligible pool this pass */
+		return;
 	spin_lock_bh(&max_pool->mutex);
```
