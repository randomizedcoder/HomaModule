# Bug 10 — TDD table

| # | Category | Scenario | Input args | Expected remote argv |
|---|---|---|---|---|
| 1 | positive | simple single command | `uptime` | `["uptime"]` |
| 2 | boundary | no extra args | *(none)* | empty; no spurious word |
| 3 | negative | quoted multi-word command | `"grep foo bar"` | `["grep foo bar"]` (one arg) |
| 4 | corner | arg containing a glob | `"ls *.log"` | `["ls *.log"]` literal, unexpanded |

The `ssh` stub echoes `"$node: $*"` from the arguments it actually received; rows 3–4 show
extra words against today's code.
