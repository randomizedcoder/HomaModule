# Homa Static Analysis Report

*Generated from the Nix flake's tiered analysis targets. Companion to
[`fuzzing-report.md`](fuzzing-report.md).*

- **Date:** 2026-09-18
- **Reproduce:** `nix build .#analysis-quick` · `.#analysis-standard` · `.#analysis-deep`
  (per-tool: `.#analysis-ruff`, `.#analysis-shell`, `.#analysis-clang-format`,
  `.#analysis-cppcheck`, `.#analysis-clang-tidy`, `.#analysis-sparse`)

## Kernel selection (affects the kernel-dependent tiers)

nixpkgs is pinned to `nixos-unstable`. At build time `linux_latest` = **7.2.6**, against
which `homa.ko` does **not** compile (upstream API drift — `homa_devel.c` /
`homa_rpc.h:539`); 6.16/6.17/6.19 were already **removed from nixpkgs as EOL**. The newest
kernel that builds Homa is **6.12.110 LTS**, so it is the flake default and the basis for
the kernel-dependent analysis. `homa-module`, `homa-module-debug`, `homa-module-6_1/6_6/6_12`
and the OCI image all build; `homa-module-latest` reproduces the 7.2.6 drift on demand.

## Results by tier

| Tier | Tool | Findings | Notes |
|---|---|---|---|
| quick | ruff (python) | **2319** | kernel-free |
| quick | shellcheck/shfmt | **5** | kernel-free |
| quick | clang-format | **35 files** | kernel-free |
| standard | cppcheck | **22** | kernel-free |
| standard | clang-tidy | **2130** | via compile DB (module built under `bear`) |
| deep | sparse (endian) | **974 raw** | mostly kernel-header noise (see below) |
| deep | smatch | available | wired when nixpkgs ships `smatch` |

## quick tier — Python (ruff): 2319 findings

The Python tooling (`util/`, `perf/`, `cloudlab/`) is pre-`argparse`-era and never linted.
Top rules:

| Rule | Count | Meaning |
|---|---|---|
| `UP031` | 1325 | `printf`-style `%` formatting → use `str.format`/f-strings |
| `PLW0602` | 318 | `global` declared but never assigned |
| `F401` | 111 | unused imports |
| `PLR1730` | 71 | if-block reducible to `min`/`max` |
| `SIM115` | 66 | open file without a context manager |
| `TRY002` | 54 | raising bare `Exception` |
| `FURB105` | 46 | redundant `print("")` |
| `PIE808` | 42 | needless `range(0, …)` |
| `F841` | 33 | unused local variable |
| `W605` | 32 | invalid escape sequence in a (non-raw) string/regex |

`W605`/`F401`/`F841` are the highest-value quick wins (real latent bugs / dead code). Note
the extensionless `util/cp_*` scripts were included via **shebang detection** — a plain
`*.py` glob would have missed them.

## quick tier — Shell (shellcheck): 5 findings

Homa has no `*.sh` files; scripts were found by shebang (`cloudlab/bin/*`, `util/*`). The one
`error`-level finding is worth fixing:

- `cloudlab/bin/on_nodes:28` — **SC2068** (error): unquoted `$@`/array expansion re-splits elements.
- `cloudlab/bin/ckill`, `set_cutoffs` — SC2034 (unused vars); `cloudlab/docker/linux-4.18.0/start` — SC2046 (word splitting).

## quick tier — clang-format: 35 files

Checked against the built-in **LinuxKernel** style (Homa follows kernel style). 35 of the
core `homa_*.c/.h` files differ from a strict LinuxKernel reformat — expected for
hand-formatted kernel code; useful as a normalization baseline, not necessarily defects.

## standard tier — cppcheck: 22 findings

Run standalone (no kernel needed), `--enable=warning,performance,portability --std=c11`:

| id | count | severity |
|---|---|---|
| `returnImplicitInt` | 11 | portability |
| `uninitvar` | 1 | error |
| `arithOperationsOnVoidPointer` | 1 | portability |
| `syntaxError` | few | error (macro/kernel constructs cppcheck can't parse without headers) |

The **`uninitvar`** (use of uninitialized variable) is the highest-priority item to review.
The `syntaxError`s are cppcheck limitations parsing kernel macros without the full include
set, not Homa defects.

## standard tier — clang-tidy: 2130 findings (≈640 substantive)

clang-tidy (`bugprone-*,cert-*,clang-analyzer-*,misc-*`) ran over the
`compile_commands.json` captured by building the module under `bear` (the heaviest analysis
step — compile DB + all 18 module TUs with real kernel headers). Breakdown:

| Check | Count | Character |
|---|---|---|
| `misc-include-cleaner` | 1355 | **noise** — "no header directly provides `u32`/`__be32`/`ntohl`" (IWYU-style; normal for kernel code) |
| `bugprone-casting-through-void` | 358 | worth review — casts routed through `void *` |
| `clang-diagnostic-error` | 136 | **noise** — clang-tidy parse errors on kernel macros out of build context |
| `bugprone-narrowing-conversions` | 91 | **actionable** — narrowing (relevant to length/offset handling) |
| `bugprone-sizeof-expression` | 22 | actionable |
| `misc-unused-parameters` | 21 | style |
| `cert-err33-c` | 21 | **actionable** — unchecked return values |
| `bugprone-assignment-in-if-condition` | 12 | review |
| `bugprone-easily-swappable-parameters` | 10 | style |
| `bugprone-implicit-widening-of-multiplication-result` | 6 | **actionable** — width bugs in multiplications (size math) |

Excluding the include-cleaner and parse-error noise (~1491) leaves **~640 substantive
findings**. The highest-value subset for Homa's wire/length code is
`bugprone-narrowing-conversions` (91), `bugprone-implicit-widening-of-multiplication-result`
(6), and `cert-err33-c` (21). Full per-file output: `nix build .#analysis-clang-tidy`
(`$out/report.txt`). Note clang-tidy over a nix-captured DB is best-effort (build-sandbox
paths remapped), so treat it as indicative.

## deep tier — sparse (`-D__CHECK_ENDIAN__`): 974 raw warnings

sparse was run through kbuild with endianness checking on, as the static complement to the
fuzzing focus on (de)serialization. **The raw count is dominated by kernel-header
preprocessor noise** — the bulk are `directive in macro's argument list` from
`include/linux/skbuff.h` and similar, i.e. sparse warnings about the 6.12 headers, not Homa
code. No `__be*`/`__force` endianness violations were surfaced in Homa's own
`homa_wire.h`/`homa_incoming.c`/`homa_outgoing.c` against 6.12. Interpretation: a weak
positive signal, but sparse's endianness value here is limited by header noise and by 6.12
being older than Homa's ~6.17 target; re-running against Homa's target kernel (once nixpkgs
carries a non-EOL build of it) would be more informative.

## Not run / limitations

- **`homa-tests`** (unit tests) do not build against 6.12: the harness assumes Homa's ~6.17
  target struct layout (e.g. `napi.gro.bitmask`) and compiles with `-Werror`, so version
  drift becomes hard errors. They need Homa's target kernel, which is EOL-removed from this
  nixpkgs. (`test/Makefile` is hardcoded `-Werror`; the flake is additive and does not edit it.)
- **smatch** is wired into the deep tier only when nixpkgs provides it.
- clang-tidy over a nix-captured compile DB is best-effort (absolute-path remapping); treat
  its output as indicative.
