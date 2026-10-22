# Bug 4 — TDD table

| # | Category | Scenario | Input (`done`, `ack`, `now` ticks) | Expected: send NEED_ACK? |
|---|---|---|---|---|
| 1 | positive | ack window elapsed | done=100, ack=10, now=120 | yes (diff crossed) |
| 2 | negative | window not yet elapsed | done=100, ack=10, now=105 | no |
| 3 | boundary | exactly at threshold | done=100, ack=10, now=109 | no (>= boundary) |
| 4 | boundary | one past threshold | done=100, ack=10, now=110 | yes |
| 5 | corner | tick counter wrapped | done=`0xFFFFFFF0`, ack=10, now=5 | yes (wrap-safe) |
