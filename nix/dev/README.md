# nix/dev: the development shell

`nix develop` opens a bash shell with every tool on `PATH` and `$KDIR` pointing at the
default kernel's build tree. Nothing is installed on the host; leaving the shell leaves
no trace.

| File | In the scope as | What it is |
|---|---|---|
| `packages.nix` | `packagesModule` | the tool lists: build inputs, analysis and debugging tools, and `pythonEnv` (python3 with the packages Homa's scripts import) |
| `env-vars.nix` | `envVars` | shell code that exports `KDIR`, `LINUX_VERSION`, `ARCH`, and puts `pythonEnv` first on `PATH` |
| `shell-functions/` | `shellFunctions` | `homa-build`, `homa-test`, `homa-clean`, `homa-checkpatch`, `homa-lint` |
| `shell.nix` | `devShell` | the `mkShell` that puts them together |

```sh
nix develop
homa-build        # make against $KDIR
homa-test         # the unit tests
homa-checkpatch   # the kernel's checkpatch.pl
homa-lint         # ruff and clang-format
```

`nix fmt` formats Nix files with `nixpkgs-fmt` ([`../parts/dev.nix`](../parts/dev.nix)).
