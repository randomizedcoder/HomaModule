# nix/cross.nix
#
# Cross-compile checks (xdp2 pattern): build Homa for other architectures on an x86_64
# host, with nixpkgs' cached cross toolchains (pkgsCross), and no emulation.
#
#   homa-module-<arch>         homa.ko for the default kernel (7.3), cross-compiled against a
#                              prepared tree (kernel-src.nix mkTree) using nixpkgs' <arch>
#                              kernel config; checks homa.ko's ELF machine
#   homa-module-<arch>-strip   ... the same for the upstream-shaped source (__STRIP__=1)
#   homa-utils-<arch>          util/ (cp_node, demo_*, ...) built with the cross toolchain
#   homa-cross-matrix          every arch: module results plus a `make -k` report of util/,
#                              in summary.md; fails only if a homa.ko does not build
#
# <arch> is riscv64 or aarch64. The kernel trees take about 2 minutes each (modules_prepare,
# no vmlinux), versus about 30 for a full cross kernel build.
#
# Usage in flake.nix:
#   crossPkgs = import ./nix/cross.nix {
#     inherit pkgs lib kernelConfig kernelSrc;
#     src = homaSrc;
#     buildAgainstTree = modulePkgs.buildAgainstTree;
#   };

{ pkgs
, lib
, kernelConfig
, kernelSrc
, src
, buildAgainstTree
}:

let
  # arch: the kernel's ARCH=; machine: what readelf -h prints for the target.
  targets = {
    riscv64 = { cross = pkgs.pkgsCross.riscv64; arch = "riscv"; machine = "RISC-V"; };
    aarch64 = { cross = pkgs.pkgsCross.aarch64-multiplatform; arch = "arm64"; machine = "AArch64"; };
  };

  # Same source as the default x86 kernel, so every arch builds the same kernel version.
  kernel = kernelConfig.kernelPackages.kernel;
  series = kernelConfig.seriesOf kernelConfig.kernelPackages;

  perTarget = name: t:
    let
      cc = t.cross.stdenv.cc;
      tree = kernelSrc.mkTree {
        name = "${name}-${series}";
        inherit (kernel) version src;
        configfile = t.cross.linuxPackages_latest.kernel.configfile;
        makeFlags = [ "ARCH=${t.arch}" "CROSS_COMPILE=${cc.targetPrefix}" ];
        extraInputs = [ cc ];
      };
      module = buildAgainstTree name tree { inherit (t) machine; };
      moduleStrip = buildAgainstTree "${name}-strip" tree { inherit (t) machine; strip = true; };
      userspace = import ./userspace.nix {
        pkgs = t.cross;
        inherit lib kernelConfig src;
      };
      utils = userspace.homa-utils;
      utilsReport = userspace.buildUtils { report = true; };
    in
    { inherit tree module moduleStrip utils utilsReport; inherit (t) machine; };

  all = lib.mapAttrs perTarget targets;

  homa-cross-matrix = pkgs.runCommand "homa-cross-matrix" { } ''
    mkdir -p "$out"
    {
      echo "# Cross-compile matrix (Linux ${kernel.version})"
      ${lib.concatMapStrings (name: let a = all.${name}; in ''
        echo
        echo "## ${name}"
        echo
        echo "- homa.ko: PASS (${a.machine}), ${a.module}"
        echo "- homa.ko (__STRIP__=1): PASS (${a.machine}), ${a.moduleStrip}"
        echo "- compiler warnings in homa.ko: $(grep -cE "^[^ ]+:[0-9]+:[0-9]+: warning:" ${a.module}/build.log || true)"
        echo
        cat ${a.utilsReport}/report.md
        cp ${a.utilsReport}/build.log "$out/utils-${name}.log"
      '') (lib.attrNames all)}
    } > "$out/summary.md"
    cat "$out/summary.md"
  '';
in
{
  inherit all homa-cross-matrix;
  packages = lib.concatMapAttrs
    (name: a: {
      "homa-module-${name}" = a.module;
      "homa-module-${name}-strip" = a.moduleStrip;
      "homa-utils-${name}" = a.utils;
      "linux-kdir-${name}-${series}" = a.tree;
    })
    all
  // { inherit homa-cross-matrix; };
}
