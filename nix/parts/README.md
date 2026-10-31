# nix/parts: the flake's outputs, one file per area

[`flake.nix`](../../flake.nix) is short: it names its inputs and lists these files. Each one
is a [flake-parts](https://flake.parts) module that sets some of the flake's outputs. The
outputs are what `nix build .#<name>`, `nix run`, `nix develop` and `nix flake check` find.

| File | Outputs |
|---|---|
| `scope.nix` | none: builds the package scope ([`../scope.nix`](../scope.nix)) and passes it to the others as `homa` |
| `build.nix` | `homa-module*`, `homa-build-matrix`, `homa-utils*`, `homa-tests`, `homa-image*`, cross builds (x86_64 hosts only); `default` is `homa-module` |
| `dev.nix` | `devShells.default` (`nix develop`) and `formatter` (`nix fmt`) |

## How a part works

`perSystem` is a function that flake-parts calls once for each system in `flake.nix`
(`x86_64-linux`, `aarch64-linux`), with `pkgs` for that system. What it returns becomes
`packages.<system>.*`, `checks.<system>.*` and so on. Several parts may each set
`packages`; flake-parts merges them, and a name defined twice is an error.

The parts hold no build logic. Each one picks outputs from the scope (`homa.analysisPkgs`
and so on), so the build code under `nix/` does not depend on flake-parts.
