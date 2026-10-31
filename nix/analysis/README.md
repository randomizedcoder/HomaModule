# nix/analysis: static analysis in three tiers

Each tool is a derivation whose output is a report (`report.txt`) and a finding count
(`count.txt`). A tier runs several tools and adds a `summary.txt`. The tools report
findings; they do not fail on them. Only `analysis-quick` is a `nix flake check`.

| Tier | Tools | Needs a kernel |
|---|---|---|
| `analysis-quick` | ruff (Python), shellcheck and shfmt (shell), clang-format | no |
| `analysis-standard` | + cppcheck, clang-tidy (from a compile database) | yes |
| `analysis-deep` | + sparse (with endianness checks), smatch | yes |

```sh
nix build .#analysis-standard && cat result/summary.txt
nix build .#analysis-sparse && less result/report.txt    # one tool
```

| File | What it is |
|---|---|
| `default.nix` | `mkAnalysisTool`, the tiers, and the per-tool `analysis-<tool>` packages |
| `python.nix`, `shell.nix`, `clang-format.nix`, `cppcheck.nix` | one `mkAnalysisTool` call each |
| `compile-db.nix` | `compile_commands.json`, recorded with `bear` around a kbuild build |
| `clang-tidy.nix` | clang-tidy over that compile database |
| `kbuild-check.nix` | a checker kbuild runs on every file (`make C=2 CHECK=...`): sparse and smatch |

## Adding a tool

```nix
mytool = mkAnalysisTool {
  name = "mytool";
  tools = [ pkgs.mytool ];
  script = "mytool . > $out/report.txt";
  count = ": warning: ";       # an extended regex matching one finding
};
```

`script` runs in a writable copy of Homa's source (`homaLib.src.module` unless `src` says
otherwise). `kbuild = true` adds the compiler and the default kernel's build dependencies.
Each tool file is called with `lib.callPackageWith`, so it names the arguments it needs
(`mkAnalysisTool`, `pkgs`, `kernelConfig`, ...) and gets just those.
