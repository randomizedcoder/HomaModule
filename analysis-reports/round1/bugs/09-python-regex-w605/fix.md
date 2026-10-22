# Bug 9 — Fix

Prefix each regex literal with `r`. Apply at all four sites.

```diff
--- a/util/rpcid.py
+++ b/util/rpcid.py
-        match = re.match(' *([-0-9.]+) us .* \[C([0-9]+)\]', line)
+        match = re.match(r' *([-0-9.]+) us .* \[C([0-9]+)\]', line)
```

The same one-character change (`'...'` → `r'...'`) applies at:

- `util/rpcid.py:144`
- `util/smi.py:32`
- `util/tput.py:40`
- `util/tthoma.py:1739`

`ruff check --select W605` confirms zero remaining occurrences afterward.
