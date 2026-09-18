# nix/module.nix
#
# The homa.ko out-of-tree kernel module, built with the standard nixpkgs kbuild idiom
# (kernel.moduleBuildDependencies + KDIR pointing at the kernel's build tree).
#
# Debug vs non-debug is a single boolean (`enableDebug`), mirroring xdp2's `enableAsserts`:
#   release: MY_CFLAGS='-O2'
#   debug:   MY_CFLAGS='-g -O1 -fno-omit-frame-pointer'
# Homa has no formal DEBUG macro, so at the C level "debug" means opt-level/symbols only.
# Real memory-safety coverage comes from the microVM's KASAN kernel (see docs/DESIGN.md §4).
#
# `buildModule` is also reused by nix/microvms/ to build the .ko against the SAME
# kernelPackages the guest boots (co-pinning avoids vermagic drift).
#
# Usage in flake.nix:
#   modulePkgs = import ./nix/module.nix { inherit pkgs lib kernelConfig; src = self; };
#   modulePkgs.homa-module          # release .ko
#   modulePkgs.homa-module-debug    # debug .ko
#   modulePkgs.packages             # { homa-module, homa-module-debug, homa-module-6_12, ... }
#   modulePkgs.buildModule { kernelPackages = <kp>; enableDebug = false; }

{ pkgs
, lib
, kernelConfig
, src
}:

let
  version = "0-unstable-${lib.substring 0 8 (src.rev or "dirty")}";

  buildModule = { kernelPackages, enableDebug ? false }:
    let
      kernel = kernelPackages.kernel;
      modDirVersion = kernel.modDirVersion;
      myCflags = if enableDebug then "-g -O1 -fno-omit-frame-pointer" else "-O2";
    in
    pkgs.stdenv.mkDerivation {
      pname = "homa-module${lib.optionalString enableDebug "-debug"}";
      inherit version src;

      nativeBuildInputs = [ pkgs.gnumake ] ++ kernel.moduleBuildDependencies;

      # Sanitizers/FORTIFY from the cc-wrapper interfere with kbuild's own flags.
      hardeningDisable = [ "all" ];

      # The top Makefile's default target `all` runs:
      #   $(MAKE) -C $(KDIR) M=$(shell pwd) modules
      # so we only need to point KDIR at this kernel's build tree.
      makeFlags = [ "KDIR=${kernelConfig.kdirOf kernelPackages}" ];

      # MY_CFLAGS (which the Makefile funnels into ccflags-y) is passed via the environment,
      # NOT makeFlags: stdenv word-splits makeFlags, which would turn the debug value's `-O1`
      # into make's own `-O` (output-sync) option. As an env var it reaches the kbuild
      # sub-make intact.
      env.MY_CFLAGS = myCflags;

      dontConfigure = true;

      installPhase = ''
        runHook preInstall
        mkdir -p "$out/lib/modules/${modDirVersion}"
        cp homa.ko "$out/lib/modules/${modDirVersion}/"
        # Record what this .ko was built against, for the microVM / debugging.
        {
          echo "modDirVersion=${modDirVersion}"
          echo "enableDebug=${lib.boolToString enableDebug}"
          echo "MY_CFLAGS=${myCflags}"
        } > "$out/lib/modules/${modDirVersion}/homa.ko.buildinfo"
        runHook postInstall
      '';

      # Never strip or patchelf a kernel module.
      dontStrip = true;
      dontPatchELF = true;

      passthru = { inherit kernelPackages modDirVersion enableDebug; };

      meta = with lib; {
        description = "Homa transport protocol Linux kernel module (homa.ko)"
          + optionalString enableDebug " [debug]";
        homepage = "https://github.com/PlatformLab/HomaModule";
        license = licenses.bsd2;
        platforms = platforms.linux;
      };
    };

  homa-module = buildModule { inherit (kernelConfig) kernelPackages; enableDebug = false; };
  homa-module-debug = buildModule { inherit (kernelConfig) kernelPackages; enableDebug = true; };

  # Compile-test matrix: homa-module-<ver> against each available LTS kernel (fallback for
  # API drift on the newest kernel).
  matrixPkgs = lib.mapAttrs'
    (name: kp: lib.nameValuePair "homa-module-${name}"
      (buildModule { kernelPackages = kp; enableDebug = false; }))
    kernelConfig.matrix;

  # Drift-demonstration target: build against nixpkgs `linux_latest`. Currently fails
  # (upstream Homa does not yet support 7.2.x); kept so the drift can be re-checked as Homa
  # and nixpkgs move. See docs/STATUS.md.
  homa-module-latest = buildModule {
    kernelPackages = kernelConfig.latest;
    enableDebug = false;
  };
in
{
  inherit buildModule homa-module homa-module-debug;
  packages = {
    inherit homa-module homa-module-debug homa-module-latest;
  } // matrixPkgs;
}
