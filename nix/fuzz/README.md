# nix/fuzz: libFuzzer harnesses for Homa's wire format

The harnesses feed random bytes to the code that decodes Homa packets, built with
libFuzzer, AddressSanitizer and UndefinedBehaviorSanitizer. [`../docs/DESIGN.md`](../docs/DESIGN.md)
§7 explains what each one covers and why.

| Output | What it is |
|---|---|
| `fuzz` | the standalone harnesses (`fuzz_dissector`, `fuzz_selftest`), which need no kernel, plus `bin/run-fuzzers` |
| `fuzz-run` | a 20 s run of each: `summary.txt`, `count.txt`, `crashes/` |
| `fuzz-deep` | a command: fork mode and the dictionary, for `FUZZ_DEEP_TIME` seconds per harness |
| `fuzz-cov` | llvm-cov coverage of the wire decoder |
| `fuzz-selftest` | a canary: fails unless the harness finds a planted bug (a `nix flake check`) |
| `fuzz-mock` | the kernel-mock harnesses: Homa's real receive path on the unit tests' mock kernel, plus `bin/run-mock-fuzzers` |

```sh
nix build .#fuzz && FUZZ_TIME=300 ./result/bin/run-fuzzers out/
nix run .#fuzz-deep -- out/
nix build .#fuzz-mock && ./result/bin/run-mock-fuzzers 600 out/
```

| Path | What it is |
|---|---|
| `default.nix` | the outputs above, and the helpers they share: `compileHarness`, `mkFuzzDrv`, `launcher` |
| `tools/run-fuzzers.sh` | the one runner every output uses: runs each harness, reproduces each crash, keeps one per sanitizer signature |
| `tools/fuzz-{cov,selftest,mock}.nix` | the builds with more to them than one compile |
| `tools/build-mock-fuzzers.sh`, `tools/gen-mock-seeds.py` | the kernel-mock build and its seed corpus; both run by hand too |
| `harness/` | the harness sources; `harness/mock/` for the kernel-mock ones |
| `corpus-seeds/`, `dict/` | starting inputs and the libFuzzer dictionary |
| `known-findings.txt` | sanitizer reports `fuzz-mock` accepts while their fix is pending |

## The runner's output

`run-fuzzers [outdir]` leaves, for each harness, its working corpus and log, and under
`crashes/<harness>/` one `crash-<sig>` input with its symbolized `repro-<sig>.txt` per
distinct crash. `summary.txt` has a line per harness. The environment sets the run:
`FUZZ_TIME` (seconds per harness), `FUZZ_FORKS`, `FUZZ_MAXLEN`, `FUZZ_DICT`.
