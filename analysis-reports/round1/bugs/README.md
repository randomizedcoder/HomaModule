# Homa — Per-Bug TDD Workspace

One directory per verified defect from [`../top-10-bugs.md`](../top-10-bugs.md). Each holds:

- **`issue.md`** — the defect, exact location, and why it bites.
- **`tdd-table.md`** — the table-driven case matrix (positive / negative / boundary / corner),
  each row with its input and expected outcome.
- **a test-code file** — the failing-first test (kselftest `TEST`/`TEST_F` for C, `pytest`
  parametrize for Python, `bats` for shell).
- **`fix.md`** — the minimal fix as a diff.

The C test files are **fragments** meant to be merged into the existing `test/unit_homa_*.c`
harness (they use its `FIXTURE`/`TEST_F` macros, `mock.c` seams, and `ARRAY_SIZE`); they do not
compile standalone. Each file's header comment names its destination and any mock helper it
assumes.

| # | Directory | Bug | Sev | Lang |
|---|---|---|---|---|
| 1 | [`01-tx-pool-max-pool-uninit`](01-tx-pool-max-pool-uninit/) | `max_pool` used uninitialized → wild deref | **H** | C |
| 2 | [`02-tx-pool-min-pages-overflow`](02-tx-pool-min-pages-overflow/) | `min_kb * 1000` `int` overflow | **M** | C |
| 3 | [`03-snprintf-va-end`](03-snprintf-va-end/) | missing `va_end` on early return | **M** | C |
| 4 | [`04-timer-signed-shift-ub`](04-timer-signed-shift-ub/) | `1 << 31` signed-shift UB | **M** | C |
| 5 | [`05-outgoing-frag-signedness`](05-outgoing-frag-signedness/) | signed/unsigned `min()` | **M** | C |
| 6 | [`06-tx-pool-void-ptr-arith`](06-tx-pool-void-ptr-arith/) | arithmetic on `void *` | **L** | C |
| 7 | [`07-data-offset-narrowing`](07-data-offset-narrowing/) | DATA offset `u32`→`int` unvalidated | **M** | C (deser) |
| 8 | [`08-grant-offset-narrowing`](08-grant-offset-narrowing/) | GRANT offset `u32`→`int` | **M** | C (deser) |
| 9 | [`09-python-regex-w605`](09-python-regex-w605/) | invalid regex escapes (W605) | **M** | Python |
| 10 | [`10-shell-unquoted-args-sc2068`](10-shell-unquoted-args-sc2068/) | unquoted `$@` (SC2068) | **M** | Shell |

## Running

- **C:** merge each fragment into its `test/unit_homa_*.c`, then `nix develop` → `homa-test`
  (or `make -C test`). Bugs 2 and 5 assume small pure helpers (`homa_tx_pool_min_pages`,
  `homa_frag_bytes`) extracted per their `fix.md` so the logic is unit-testable.
- **Python:** `python -W error::DeprecationWarning -m pytest 09-python-regex-w605/`.
- **Shell:** `bats 10-shell-unquoted-args-sc2068/on_nodes.bats` with `on_nodes` on `PATH`.

Every test is written to **fail against the current tree** and **pass after the paired fix** —
standard red/green TDD.
