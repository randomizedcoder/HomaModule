# Bug 10 — Fix

Quote both the host and the forwarded argument list.

```diff
--- a/cloudlab/bin/on_nodes
+++ b/cloudlab/bin/on_nodes
-    ssh -4 $node $@
+    ssh -4 "$node" "$@"
```

`shellcheck cloudlab/bin/on_nodes` reports no SC2068 afterward.
