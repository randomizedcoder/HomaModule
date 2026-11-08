# nix/build: homa.ko, the user-space tools, the unit tests, the OCI image

| File | Outputs |
|---|---|
| `module.nix` | `homa-module` (the default kernel), `homa-module-debug` (`-g -O1`), `homa-module-<series>` for every nixpkgs kernel, `homa-module-local` (your tree, `--impure`), and `homa-build-matrix`, which tries every kernel and writes `summary.md` |
| `userspace.nix` | `homa-utils[-debug]` (`util/`; `-debug` adds ASan) and `homa-tests`, which builds and runs the unit tests in `test/` |
| `cross.nix` | `homa-module-{riscv64,aarch64}[-strip]`, `homa-utils-{riscv64,aarch64}`, `linux-kdir-<arch>-<series>` and `homa-cross-matrix` (x86_64 hosts only) |
| `oci.nix` | `homa-image[-debug]`: the user-space tools in an OCI image (`docker load < result`) |

```sh
nix build .#homa-module               # result/lib/modules/<version>/homa.ko
nix build .#homa-build-matrix && cat result/summary.md
nix build .#homa-tests                # fails if a unit test fails
```

## How the module build works

Homa's own `Makefile` does the work, as it would by hand: `make KDIR=<kernel build tree>`.
`homaLib.mkKbuild` ([`../lib`](../lib)) wraps that in a derivation: the source is
`homaLib.src.module`, the kernel tree comes from [`../kernel`](../kernel), and kbuild's
own flags replace nixpkgs' hardening flags. A build is one function call per kernel:

```nix
buildModule { kernelPackages = pkgs.linuxPackages_6_12; enableDebug = true; }
```

`homa-build-matrix` does not fail when a kernel fails. Its job is the table: which kernels
Homa builds on today.

## Cross builds

`cross.nix` uses nixpkgs' `pkgsCross.<arch>`, a copy of nixpkgs whose compilers target
another architecture. Calling `userspace.nix` through `pkgsCross.riscv64.callPackage` is
all it takes to cross-compile the tools; the module builds against a riscv64 or aarch64
kernel tree prepared from source.
