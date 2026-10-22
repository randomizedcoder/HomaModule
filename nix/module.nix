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
#   modulePkgs = import ./nix/module.nix { inherit pkgs lib kernelConfig kernelSrc; src = homaSrc; };
#   modulePkgs.homa-module          # release .ko (default kernel)
#   modulePkgs.homa-module-debug    # debug .ko
#   modulePkgs.packages             # { homa-module, homa-module-debug, homa-module-<series>...,
#                                   #   homa-build-matrix }
#   modulePkgs.buildModule { kernelPackages = <kp>; enableDebug = false; }
#
# Per-kernel targets:
#   homa-module-<series>   nixpkgs kernels (kernel.nix matrix): a real .ko, loadable in the
#                          matching microVM.
#   homa-module-<series>   kernel-src trees (7.0-7.2, local): compile check only, built with
#                          KBUILD_MODPOST_WARN=1 because those trees have no Module.symvers.
#   homa-build-matrix      one derivation that tries every kernel above and writes a
#                          pass/fail table plus logs; it never fails itself.

{ pkgs
, lib
, kernelConfig
, kernelSrc
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

  # Compile-only builds against kernels prepared from source (nix/kernel-src.nix).
  buildAgainstTree = name: tree: pkgs.stdenv.mkDerivation {
    pname = "homa-module-${name}";
    inherit version src;
    nativeBuildInputs = [ pkgs.gnumake ] ++ tree.nativeBuildInputs;
    buildInputs = tree.buildInputs;
    hardeningDisable = [ "all" ];
    dontConfigure = true;
    makeFlags = [ "KDIR=${tree}/build" "KBUILD_MODPOST_WARN=1" ];
    env.MY_CFLAGS = "-O2";
    installPhase = ''
      mkdir -p "$out"
      cp homa.ko "$out/"
    '';
    dontFixup = true;
  };
  srcPkgs = lib.mapAttrs'
    (name: tree: lib.nameValuePair "homa-module-${name}" (buildAgainstTree name tree))
    kernelSrc.trees;

  # Every kernel, one report. Each build runs in its own copy of the source; a failure is
  # recorded, not propagated, so one broken kernel does not hide the others.
  matrixKdirs =
    lib.mapAttrsToList (n: kp: { name = n; version = kp.kernel.version; kdir = kernelConfig.kdirOf kp; extra = ""; })
      kernelConfig.matrix
    ++ lib.mapAttrsToList (n: t: { name = n; version = t.version; kdir = "${t}/build"; extra = "KBUILD_MODPOST_WARN=1"; })
      kernelSrc.trees;

  homa-build-matrix = pkgs.stdenv.mkDerivation {
    pname = "homa-build-matrix";
    inherit version src;
    nativeBuildInputs = [ pkgs.gnumake ]
      ++ kernelConfig.kernelPackages.kernel.moduleBuildDependencies
      ++ (with pkgs; [ elfutils openssl ]);
    hardeningDisable = [ "all" ];
    dontConfigure = true;
    buildPhase = ''
      mkdir -p "$out/logs"
      printf '| Kernel | Version | Result |\n|---|---|---|\n' > "$out/summary.md"
      fail=0
      ${lib.concatMapStrings (k: ''
        rm -rf "../w-${k.name}"; cp -r . "../w-${k.name}"; chmod -R u+w "../w-${k.name}"
        if make -C "../w-${k.name}" KDIR=${k.kdir} ${k.extra} MY_CFLAGS=-O2 \
            -j"$NIX_BUILD_CORES" > "$out/logs/${k.name}.log" 2>&1; then
          r=PASS
        else
          r=FAIL; fail=$((fail + 1))
        fi
        echo "| ${k.name} | ${k.version} | $r |" >> "$out/summary.md"
        rm -rf "../w-${k.name}"
      '') matrixKdirs}
      echo "$fail" > "$out/failures"
      cat "$out/summary.md"
    '';
    dontInstall = true;
    dontFixup = true;
  };
in
{
  inherit buildModule homa-module homa-module-debug homa-build-matrix;
  packages = {
    inherit homa-module homa-module-debug homa-build-matrix;
  } // srcPkgs // matrixPkgs;
}
