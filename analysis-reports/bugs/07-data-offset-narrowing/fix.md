# Bug 7 — Fix

Read the wire field as unsigned and validate before use.

```diff
--- a/homa_incoming.c
+++ b/homa_incoming.c
@@ homa_data_pkt copy-out loop
-		int offset = ntohl(h->seg.offset);
+		u32 offset = ntohl(h->seg.offset);
+
+		if (offset >= rpc->msgin.length) {
+			homa_data_drop(skb, "offset out of range");
+			continue;
+		}
```

`homa_data_drop()` stands in for the file's existing drop/free path; use whatever discard
helper the surrounding loop already uses so metrics/refcounts stay correct.
