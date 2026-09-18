# nix/userspace.nix
#
# User-space derivations:
#   homa-utils        - the util/ benchmark/test binaries (release, mirrors util/Makefile -O3)
#   homa-utils-debug  - the same, with AddressSanitizer injected via the cc-wrapper
#   homa-tests        - build + run the test/ kselftest-style unit harness (ASan)
#
# The test harness compiles the kernel C files in user space against the pinned kernel's
# headers, so it needs KDIR + ARCH=x86 (test/Makefile hardcodes x86 include paths). This is
# kernel-version sensitive; if it fails against the newest kernel that is recorded in
# docs/STATUS.md and the static-analysis report (see docs/DESIGN.md §5).
#
# Usage in flake.nix:
#   userspacePkgs = import ./nix/userspace.nix { inherit pkgs lib kernelConfig; src = self; };

{ pkgs
, lib
, kernelConfig
, src
}:

let
  version = "0-unstable-${lib.substring 0 8 (src.rev or "dirty")}";

  buildUtils = { debug ? false }:
    pkgs.stdenv.mkDerivation {
      pname = "homa-utils${lib.optionalString debug "-debug"}";
      inherit version src;

      nativeBuildInputs = [ pkgs.gnumake ];
      hardeningDisable = [ "all" ];

      # Inject debug/ASan without editing util/Makefile (the cc-wrapper honours these).
      NIX_CFLAGS_COMPILE = lib.optionalString debug "-g -fno-omit-frame-pointer -fsanitize=address";
      NIX_LDFLAGS = lib.optionalString debug "-fsanitize=address";

      dontConfigure = true;

      buildPhase = ''
        runHook preBuild
        make -C util -j"$NIX_BUILD_CORES" all
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin"
        # Install every executable the Makefile produced under util/.
        for f in util/*; do
          if [ -f "$f" ] && [ -x "$f" ]; then
            install -m755 "$f" "$out/bin/"
          fi
        done
        runHook postInstall
      '';

      meta = with lib; {
        description = "Homa user-space test/benchmark tools (util/)"
          + optionalString debug " [ASan]";
        license = licenses.bsd2;
        platforms = platforms.linux;
      };
    };

  homa-utils = buildUtils { debug = false; };
  homa-utils-debug = buildUtils { debug = true; };

  homa-tests = pkgs.stdenv.mkDerivation {
    pname = "homa-tests";
    inherit version src;

    nativeBuildInputs = [ pkgs.gnumake pkgs.perl ];
    hardeningDisable = [ "all" ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      # test/Makefile hardcodes $(KDIR)/include/... and $(KDIR)/arch/x86/include/..., but
      # nixpkgs splits the kernel into source/ (checked-in headers) and build/ (generated).
      # Build a merged KDIR symlink tree so those hardcoded paths resolve. (We can't edit
      # test/Makefile — the flake is purely additive.)
      buildK="${kernelConfig.kdir}"
      srcK="$(dirname "$buildK")/source"
      K="$TMPDIR/merged-kdir"
      mkdir -p "$K/include" "$K/arch/x86/include"
      cp -rs "$srcK/include/." "$K/include/" 2>/dev/null || true
      cp -rs "$srcK/arch/x86/include/." "$K/arch/x86/include/" 2>/dev/null || true
      ln -sfn "$buildK/include/generated" "$K/include/generated"
      ln -sfn "$buildK/arch/x86/include/generated" "$K/arch/x86/include/generated"

      make -C test \
        KDIR="$K" \
        LINUX_VERSION=${kernelConfig.modDirVersion} \
        ARCH=x86 \
        -j"$NIX_BUILD_CORES" unit
      runHook postBuild
    '';

    # Run the unit tests as the check step (default IPv6 path).
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      ./test/unit
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      install -m755 test/unit "$out/bin/homa-unit"
      runHook postInstall
    '';

    meta = with lib; {
      description = "Homa kselftest-style unit tests (built + run under AddressSanitizer)";
      license = licenses.bsd2;
      platforms = platforms.linux;
    };
  };
in
{
  inherit homa-utils homa-utils-debug homa-tests;
  packages = { inherit homa-utils homa-utils-debug homa-tests; };
}
