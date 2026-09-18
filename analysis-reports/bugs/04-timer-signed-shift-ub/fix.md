# Bug 4 — Fix

Compute the difference as `u32` and test the high bit with an unsigned mask.

```diff
--- a/homa_timer.c
+++ b/homa_timer.c
@@ need-ack window test
-			if ((rpc->done_timer_ticks + homa->request_ack_ticks
-					- 1 - homa->timer_ticks) & 1 << 31) {
+			if ((u32)(rpc->done_timer_ticks + homa->request_ack_ticks
+					- 1 - homa->timer_ticks) & (1u << 31)) {
```
