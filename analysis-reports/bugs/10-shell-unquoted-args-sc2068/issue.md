# Bug 10 — unquoted `$@` re-splits arguments (SC2068) **[M]**

**File:** `cloudlab/bin/on_nodes:28`
**Severity:** M — argument word-splitting / glob expansion

## Issue

```bash
ssh -4 $node $@
```

Unquoted `$@` undergoes word-splitting and glob expansion, so a remote command containing
spaces or globbing characters (`ssh ... 'grep foo bar.txt'`, or a path with `*`) is torn into
the wrong number of arguments. The correct form preserves each argument verbatim with `"$@"`
(and quotes `$node`).

See [`tdd-table.md`](tdd-table.md), [`on_nodes.bats`](on_nodes.bats), and [`fix.md`](fix.md).
