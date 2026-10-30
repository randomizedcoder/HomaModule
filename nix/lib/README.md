# nix/lib: homaLib, what every Homa build shares

`default.nix` is a set of values and functions, not a package. The scope
([`../scope.nix`](../scope.nix)) builds it once as `homaLib`, and any file that names
`homaLib` in its argument list gets it.

| Name | What it is |
|---|---|
| `src.module` | Homa's top-level C sources, Makefiles and Kconfig: what kbuild reads |
| `src.util`, `src.test` | the same, plus `util/` (and `test/`) |
| `src.fuzz` | plus `util/`, `test/` and `nix/fuzz/` |
| `src.all` | the whole tree, for the linters |
| `version`, `meta`, `rev` | for every Homa derivation; `rev` is the flake's git revision |
| `mkKbuild { kdir, makeFlags, ... }` | a derivation that runs Homa's Makefile against a kernel tree |
| `perKernel prefix f set` | `{ "<prefix>-<series>" = f series value; }` for a set keyed by kernel series |

## Why the source is cut into subsets

A Nix build depends on every byte of its source. Built from the whole repository, `homa.ko`
would rebuild whenever a README changed. Each subset is made with `lib.fileset` and holds
only what one kind of build reads, so a change outside it leaves the build cached. Markdown
files are left out of every subset but `all`. For the same reason, `version` does not
contain the git revision.

Each subset also has the patches in [`../patches`](../patches) applied. A patch is cut down
to the files in the subset first (`filterdiff`), so a fix that also adds a unit test still
applies to `src.module`, which has no `test/`.

## Nix idioms used here

- `lib.fileset.toSource { root; fileset; }` copies only the listed files into the store.
- `pkgs.applyPatches` is a derivation whose output is its source with patches applied.
- `mkKbuild`'s `args // { ... }` merges attribute sets: the right side wins, which is how
  `makeFlags` and `nativeBuildInputs` are appended to instead of replaced.
