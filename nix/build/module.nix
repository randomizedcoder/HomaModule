# nix/build/module.nix
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
# Usage (nix/scope.nix calls this file with callPackage):
#   modulePkgs.homa-module          # release .ko (default kernel)
#   modulePkgs.packages             # { homa-module, homa-module-debug, homa-module-<series>...,
#                                   #   homa-build-matrix }
#   modulePkgs.buildModule { kernelPackages = <kp>; enableDebug = false; }
#
# Per-kernel targets:
#   homa-module-<series>   nixpkgs kernels (kernel/config.nix matrix): a real .ko, loadable in the
#                          matching microVM.
#   homa-module-<series>   kernel-src trees (7.0-7.2, local): compile check only, built with
#                          KBUILD_MODPOST_WARN=1 because those trees have no Module.symvers.
#   homa-build-matrix      one derivation that tries every kernel above and writes a
#                          pass/fail table plus logs; it never fails itself.

{ pkgs
, lib
, homaLib
, kernelConfig
, kernelSrc
}:

let
  inherit (homaLib) mkKbuild perKernel;

  buildModule = { kernelPackages, enableDebug ? false }:
    let
      kernel = kernelPackages.kernel;
      modDirVersion = kernel.modDirVersion;
      myCflags = if enableDebug then "-g -O1 -fno-omit-frame-pointer" else "-O2";
    in
    mkKbuild {
      pname = "homa-module${lib.optionalString enableDebug "-debug"}";
      # The top Makefile's default target `all` runs:
      #   $(MAKE) -C $(KDIR) M=$(shell pwd) modules
      # so we only need to point KDIR at this kernel's build tree.
      kdir = kernelConfig.kdirOf kernelPackages;
      nativeBuildInputs = kernel.moduleBuildDependencies;
      env.MY_CFLAGS = myCflags;

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

      meta = homaLib.meta // {
        description = "Homa transport protocol Linux kernel module (homa.ko)"
          + lib.optionalString enableDebug " [debug]";
      };
    };

  homa-module = buildModule { inherit (kernelConfig) kernelPackages; };
  homa-module-debug = buildModule { inherit (kernelConfig) kernelPackages; enableDebug = true; };

  # Compile-test matrix: homa-module-<ver> against each nixpkgs kernel (fallback for
  # API drift on the newest kernel).
  matrixPkgs = perKernel "homa-module"
    (_: kp: buildModule { kernelPackages = kp; })
    kernelConfig.matrix;

  # Compile-only builds against kernels prepared from source (nix/kernel/src.nix). A cross
  # tree (cross.nix) brings its ARCH=/CROSS_COMPILE= flags and its cross gcc along.
  #   strip: build the upstream-shaped source (make __STRIP__=1)
  #   machine: if set, readelf must report this e_machine for homa.ko (e.g. "RISC-V")
  buildAgainstTree = name: tree: { strip ? false, machine ? null }: mkKbuild {
    pname = "homa-module-${name}";
    kdir = "${tree}/build";
    nativeBuildInputs = tree.nativeBuildInputs;
    buildInputs = tree.buildInputs;
    makeFlags = [ "KBUILD_MODPOST_WARN=1" ] ++ tree.makeFlags
      ++ lib.optional strip "__STRIP__=1";
    # Keep the log, so homa-cross-matrix can count compiler warnings.
    buildPhase = ''
      runHook preBuild
      make -j"$NIX_BUILD_CORES" $makeFlags 2>&1 | tee build.log
      runHook postBuild
    '';
    installPhase = ''
      ${lib.optionalString (machine != null) ''
        readelf -h homa.ko | grep -q 'Machine: *${machine}' \
          || { readelf -h homa.ko; echo "homa.ko is not ${machine}"; exit 1; }
      ''}
      mkdir -p "$out"
      cp homa.ko build.log "$out/"
    '';
    dontFixup = true;
  };
  srcPkgs = perKernel "homa-module"
    (name: tree: buildAgainstTree name tree { })
    kernelSrc.trees;

  # Every kernel, one report. Each build runs in its own copy of the source; a failure is
  # recorded, not propagated, so one broken kernel does not hide the others.
  matrixKdirs =
    lib.mapAttrsToList (n: kp: { name = n; version = kp.kernel.version; kdir = kernelConfig.kdirOf kp; extra = ""; })
      kernelConfig.matrix
    ++ lib.mapAttrsToList (n: t: { name = n; version = t.version; kdir = "${t}/build"; extra = "KBUILD_MODPOST_WARN=1"; })
      kernelSrc.trees;

  homa-build-matrix = mkKbuild {
    pname = "homa-build-matrix";
    nativeBuildInputs = kernelConfig.kernelPackages.kernel.moduleBuildDependencies
      ++ (with pkgs; [ elfutils openssl ]);
    buildPhase = ''
      mkdir -p "$out/logs"
      printf '| Kernel | Version | Result |\n|---|---|---|\n' > "$out/summary.md"
      fail=0
      ${lib.concatMapStrings (k: ''
        rm -rf "../w-${k.name}"; cp -r . "../w-${k.name}"; chmod -R u+w "../w-${k.name}"
        if make -C "../w-${k.name}" KDIR=${k.kdir} ${k.extra} \
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
  inherit buildModule buildAgainstTree homa-module;
  packages = {
    inherit homa-module homa-module-debug homa-build-matrix;
  } // srcPkgs // matrixPkgs;
}
