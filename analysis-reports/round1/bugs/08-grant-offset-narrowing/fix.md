# Bug 8 — Fix

Read the wire field as unsigned and clamp to the message length.

```diff
--- a/homa_incoming.c
+++ b/homa_incoming.c
@@ homa_grant_pkt
-	int new_offset = ntohl(h->offset);
+	u32 new_offset = ntohl(h->offset);
@@ apply the grant
-		if (new_offset > rpc->msgout.granted) {
-			rpc->msgout.granted = new_offset;
-			if (new_offset > rpc->msgout.length)
-				rpc->msgout.granted = rpc->msgout.length;
-		}
+		if (new_offset > rpc->msgout.granted)
+			rpc->msgout.granted = min_t(u32, new_offset,
+						    rpc->msgout.length);
```
