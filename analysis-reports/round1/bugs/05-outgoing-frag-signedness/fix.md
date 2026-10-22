# Bug 5 — Fix

Subtract in a signed domain, then `min()` two `int`s.

```diff
--- a/homa_outgoing.c
+++ b/homa_outgoing.c
@@ per-frag copy loop
-		frag_bytes = min(skb_frag_size(msg_frag) - bytes_to_skip,
-				 bytes_left);
+		int avail = (int)skb_frag_size(msg_frag) - bytes_to_skip;
+
+		frag_bytes = min(avail, bytes_left);
```

Optional helper the test drives directly:

```c
int homa_frag_bytes(u32 frag_size, int skip, int left)
{
	int avail = (int)frag_size - skip;

	return min(avail, left);
}
```
