# nix/kernel: which kernels Homa is built and tested against

| File | In the scope as | What it is |
|---|---|---|
| `config.nix` | `kernelConfig` | the default kernel (nixpkgs `linuxPackages_latest`), its `kdir`, the per-series `matrix` of nixpkgs kernels, and `vmMatrix`, the series the microVMs boot (those in `vmSeries`) |
| `src.nix` | `kernelSrc` | kernel trees prepared from kernel.org tarballs (7.0 to 7.2) or a local checkout (`HOMA_LINUX_SRC`, with `--impure`), for compile checks; its `mkTree` also makes the riscv64 and aarch64 trees in [`../build/cross.nix`](../build/cross.nix) |
| `unit-kdir/` | `unitKdir` | one merged tree for the unit tests (`test/`) and the kernel-mock fuzzers, with the compiler flags they need on a nixpkgs kernel |

To change the default kernel, edit `kernelPackages` in `config.nix`; every module build,
VM and test follows. To add a kernel to the VM tests, add its series to `vmSeries`. The
VM targets (`homa-microvm-test-<series>` and so on) and the port allocation follow from
that list.

## Why the trees need preparing

A kernel module builds against a kernel's build tree (`KDIR`): its headers, its `.config`
and the generated files. nixpkgs ships this for the kernels it packages, as
`kernel.dev`. For a kernel nixpkgs does not package, `src.nix` runs
`make olddefconfig modules_prepare` on the source itself. nixpkgs splits a tree into `source/` and `build/`; Homa's
`test/Makefile` expects one tree, which `unit-kdir` provides as a tree of symlinks.
