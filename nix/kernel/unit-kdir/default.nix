# nix/kernel/unit-kdir/default.nix
#
# A KDIR tailored for Homa's user-space unit harness (test/) and the kernel-mock fuzzers.
#
# Homa's test/Makefile hardcodes $(KDIR)/include/... and $(KDIR)/arch/x86/include/..., but
# nixpkgs splits a kernel into source/ (checked-in headers) and build/ (generated). This
# derivation merges them into one symlink tree, and swaps in a patched copy of
# include/generated/autoconf.h so that the distro config matches what test/mock.[ch]
# assumes (see patch-autoconf.sh): no gcc named-address-space per-cpu, no memory
# allocation profiling, and CONFIG_DEBUG_PREEMPT (mock.c defines preempt_count_add()).
#
# It also exposes the extra compiler flags needed against the nixpkgs kernel:
#   -fcf-protection=branch       the config enables X86_KERNEL_IBT (nocf_check attributes)
#   -include homa_unit_compat.h  small API renames vs. the vendored test/*_v6_17_8.c sources
#   -Wno-error=...               diagnostics newer gcc emits on Homa that are not
#                                harness problems (reported separately by the analysis)
#
# Nothing in the source tree is modified: everything is passed via KDIR= and CC=.
#
# Usage:
#   unitKdir (in nix/scope.nix), used by userspace.nix and fuzz/tools/fuzz-mock.nix:
#   make -C test KDIR=${unitKdir} CC="gcc ${unitKdir.extraCFlags}" unit

{ pkgs
, lib
, kernelConfig
}:

let
  unitKp = kernelConfig.unitKernelPackages;
  buildK = kernelConfig.kdirOf unitKp;
  compatHeader = ./homa_unit_compat.h;

  kdir = pkgs.runCommand "homa-unit-kdir-${unitKp.kernel.modDirVersion}" { } ''
    srcK="$(dirname "${buildK}")/source"
    mkdir -p "$out/include/generated" "$out/arch/x86/include"
    cp -rs "$srcK/include/." "$out/include/"
    cp -rs "$srcK/arch/x86/include/." "$out/arch/x86/include/"
    cp -rs "${buildK}/include/generated/." "$out/include/generated/"
    ln -sfn "${buildK}/arch/x86/include/generated" "$out/arch/x86/include/generated"
    chmod -R u+w "$out/include/generated"
    rm -f "$out/include/generated/autoconf.h"
    ${pkgs.bash}/bin/bash ${./patch-autoconf.sh} \
      "${buildK}/include/generated/autoconf.h" "$out/include/generated/autoconf.h"
  '';
in
kdir // {
  extraCFlags = lib.concatStringsSep " " [
    "-fcf-protection=branch"
    "-include ${compatHeader}"
    "-Wno-error=unused-but-set-variable"
    "-Wno-error=incompatible-pointer-types"
  ];
}
