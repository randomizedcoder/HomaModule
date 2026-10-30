# nix/kernel-src.nix
#
# Kernel build trees prepared from SOURCE, for compile-testing homa.ko against kernels that
# nixpkgs no longer ships (7.0-7.2 are EOL-removed) or has not released (a local checkout of
# net-next / mainline).
#
# Each tree is the kernel source plus `make olddefconfig modules_prepare` in an O= build
# directory, configured from nixpkgs' newest kernel config. That is enough for
# `make -C <tree> M=... modules`, but not a bootable kernel: there is no vmlinux and no
# Module.symvers, so module builds against it need KBUILD_MODPOST_WARN=1. About 2 minutes
# per tree, versus ~30 for a full kernel build.
#
# Sources:
#   tarballs   pinned kernel.org releases below (hashes checked against sha256sums.asc)
#   local      HOMA_LINUX_SRC=/path/to/linux, only with --impure; e.g.
#                HOMA_LINUX_SRC=~/Downloads/linux nix build --impure .#homa-build-matrix
#
# Usage in flake.nix:
#   kernelSrc = import ./nix/kernel-src.nix { inherit pkgs lib; };
#   kernelSrc.trees     # { "7_0" = <drv>; "7_1" = <drv>; "7_2" = <drv>; [ local = <drv>; ] }
#   "${kernelSrc.trees."7_1"}/build"   # KDIR

{ pkgs
, lib
}:

let
  # Config source for every tree; olddefconfig fills in or drops symbols per version.
  configKernel = pkgs.linuxPackages_latest.kernel;

  tarballs = {
    "7_0" = { version = "7.0.14"; hash = "sha256-3pmZt4TSKT8A05xi2PkqCKuKVLxOgP/SUKDAnLB6D5g="; };
    "7_1" = { version = "7.1.13"; hash = "sha256-YU2V+v3LXM4rZiDn7cavu2Br/9RlVAVYaBXYRoeEGtc="; };
    "7_2" = { version = "7.2.12"; hash = "sha256-uxhGio3Il4qgDKpkRudT97baP+5Wtrfzixb5QwugLU8="; };
  };

  # Large source directories that out-of-tree module builds never read.
  prune = [ "Documentation" "drivers" "sound" "samples" "fs" "LICENSES" ];

  # mkTree is also used by cross.nix: configfile is that arch's nixpkgs kernel config, and
  # makeFlags carries ARCH= and CROSS_COMPILE= (the cross gcc goes in extraInputs).
  mkTree =
    { name
    , version
    , src
    , configfile ? configKernel.configfile
    , makeFlags ? [ ]
    , extraInputs ? [ ]
    }: pkgs.stdenv.mkDerivation {
      pname = "linux-kdir-${name}";
      inherit version src;

      nativeBuildInputs = with pkgs; [ bc bison flex perl python3 pkg-config ]
        ++ configKernel.moduleBuildDependencies ++ extraInputs;
      buildInputs = with pkgs; [ elfutils openssl zlib ];
      hardeningDisable = [ "all" ];
      dontConfigure = true;

      # The O= build tree records the absolute source path, so the source must live in $out
      # too. Build into $out directly.
      buildPhase = ''
        runHook preBuild
        mkdir -p "$out"
        cp -r . "$out/source"
        chmod -R u+w "$out/source"
        patchShebangs "$out/source/scripts" "$out/source/tools"
        cd "$out/source"
        mkdir -p "$out/build"
        cp ${configfile} "$out/build/.config"
        make O="$out/build" ${toString makeFlags} olddefconfig
        make O="$out/build" ${toString makeFlags} -j"$NIX_BUILD_CORES" modules_prepare
        # Keep enough source for M= builds (headers, scripts, arch, Kbuild/Kconfig files).
        rm -rf ${lib.concatMapStringsSep " " (d: "\"$out/source/${d}\"") prune}
        runHook postBuild
      '';
      dontInstall = true;
      dontFixup = true;

      passthru = { inherit name makeFlags extraInputs; kdir = "build"; };
    };

  fromTarball = name: { version, hash }: mkTree {
    inherit name version;
    src = pkgs.fetchurl {
      url = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${version}.tar.xz";
      inherit hash;
    };
  };

  localPath = builtins.getEnv "HOMA_LINUX_SRC";
  localTree = mkTree {
    name = "local";
    version = "local";
    src = builtins.path {
      name = "linux-local-src";
      path = localPath;
      filter = p: _: baseNameOf p != ".git";
    };
  };
in
{
  inherit mkTree;
  trees = lib.mapAttrs fromTarball tarballs
    // lib.optionalAttrs (localPath != "") { local = localTree; };
}
