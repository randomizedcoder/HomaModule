# Bug 9 — invalid regex escape sequences in non-raw strings (W605) **[M]**

**Files:** `util/rpcid.py:144`, `util/smi.py:32`, `util/tput.py:40`, `util/tthoma.py:1739`
**Severity:** M — `DeprecationWarning` now, future `SyntaxError`

## Issue

Patterns such as `re.match(' *([-0-9.]+) us .* \[C([0-9]+)\]', line)` use `\[` and `\]` inside a
**non-raw** string. Python treats an unknown escape (`\[`) as a literal backslash today but
raises `DeprecationWarning` now and will become a `SyntaxError`. All regex literals should be
raw strings.

See [`tdd-table.md`](tdd-table.md), [`test_trace_line.py`](test_trace_line.py),
and [`fix.md`](fix.md).
