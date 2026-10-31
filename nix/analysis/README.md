# nix/analysis: static analysis in tiers

Each tool is a derivation whose output is a report (`report.txt`) and a finding count
(`count.txt`). A tier runs several tools and adds a `summary.txt`. The tools report
findings; they do not fail on them. Only `analysis-quick` is a `nix flake check`.

| Tier | Tools | Needs a kernel |
|---|---|---|
| `analysis-quick` | ruff (Python), shellcheck and shfmt (shell), clang-format | no |
| `analysis-standard` | + cppcheck, clang-tidy (from a compile database) | yes |
| `analysis-deep` | + sparse (with endianness checks), smatch | yes |
| `analysis-netdev` | netdev's checks on the code as submitted (below) | yes |

```sh
nix build .#analysis-standard && cat result/summary.txt
nix build .#analysis-sparse && less result/report.txt    # one tool
```

`analysis-netdev` checks what a reviewer on netdev would see: the upstream-shaped source
that `make net-next` writes (`util/strip.py`), placed in the default kernel's tree as
`net/homa`, with `net/Kconfig` and `net/Makefile` wired as an upstream patch would. Its
tools are `checkpatch.pl --strict --codespell`, `kernel-doc -Wall`, and in-tree `make W=1`
builds of `net/homa` with gcc and sparse, clang (`LLVM=1`), and 32-bit x86 (`ARCH=i386`).
A build that never compiles a `net/homa` file fails, rather than reporting zero.
`analysis-netdev-tree` is that kernel tree, for trying a fix by hand.

| File | What it is |
|---|---|
| `default.nix` | `mkAnalysisTool`, the tiers, and the per-tool `analysis-<tool>` packages |
| `python.nix`, `shell.nix`, `clang-format.nix`, `cppcheck.nix` | one `mkAnalysisTool` call each |
| `compile-db.nix` | `compile_commands.json`, recorded with `bear` around a kbuild build |
| `clang-tidy.nix` | clang-tidy over that compile database |
| `kbuild-check.nix` | a checker kbuild runs on every file (`make C=2 CHECK=...`): sparse and smatch |
| `netdev.nix` | the `analysis-netdev` tree and its five checks |

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
