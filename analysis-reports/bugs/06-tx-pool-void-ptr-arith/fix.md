# Bug 6 — Fix

Use a byte-typed pointer instead of `void *` arithmetic.

```diff
--- a/homa_tx_pool.c
+++ b/homa_tx_pool.c
@@ skb_frag_foreach_page loop
-			void *vaddr = kmap_local_page(p);
+			char *vaddr = kmap_local_page(p);

 			result = copy_from_iter(vaddr + p_off, p_len, iter);
```
