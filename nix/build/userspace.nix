# nix/build/userspace.nix
#
# User-space derivations:
#   homa-utils        - the util/ benchmark/test binaries (release, mirrors util/Makefile -O3)
#   homa-utils-debug  - the same, with AddressSanitizer injected via the cc-wrapper
#   homa-tests        - build + run the test/ kselftest-style unit harness (ASan)
#   homa-tests-coverage - the same run built with gcov: line/branch coverage of Homa's sources
#
# The test harness compiles the kernel C files in user space against the pinned kernel's
# headers, so it needs KDIR + ARCH=x86 (test/Makefile hardcodes x86 include paths). This is
# kernel-version sensitive; if it fails against the newest kernel that is recorded in
# nix/STATUS.md and the static-analysis report (see docs/DESIGN.md §5).
#
# nix/scope.nix calls this file with callPackage (and cross.nix from each cross package set).

{ pkgs
, lib
, homaLib
, unitKdir
}:

let
  inherit (homaLib) version;

  # report = true (cross.nix) runs `make -k` and never fails: $out/report.md says which
  # util/ objects and programs built, with each failing file's first error.
  buildUtils = { debug ? false, report ? false }:
    pkgs.stdenv.mkDerivation {
      pname = "homa-utils${lib.optionalString debug "-debug"}${lib.optionalString report "-report"}";
      inherit version;
      src = homaLib.src.util;

      nativeBuildInputs = [ pkgs.gnumake ];
      hardeningDisable = [ "all" ];

      # Inject debug/ASan without editing util/Makefile (the cc-wrapper honours these).
      # NIX_CFLAGS_LINK, not NIX_LDFLAGS: these go to gcc when it links, NIX_LDFLAGS to ld,
      # which rejects -fsanitize.
      env = lib.optionalAttrs debug {
        NIX_CFLAGS_COMPILE = "-g -fno-omit-frame-pointer -fsanitize=address";
        NIX_CFLAGS_LINK = "-fsanitize=address";
      };

      dontConfigure = true;

      # util/Makefile calls g++ by name. When cross-compiling (cross.nix) that must be the
      # target compiler, so put a g++ that is $CXX first on PATH.
      buildPhase = ''
        runHook preBuild
        ${lib.optionalString (pkgs.stdenv.hostPlatform != pkgs.stdenv.buildPlatform) ''
          mkdir -p .cross-bin
          ln -s "$(command -v "$CXX")" .cross-bin/g++
          ln -s "$(command -v "$CC")" .cross-bin/gcc
          ln -s "$(command -v "$CC")" .cross-bin/cc
          export PATH="$PWD/.cross-bin:$PATH"
        ''}
        ${if report then ''
          mkdir -p "$out"
          make -C util -k -j"$NIX_BUILD_CORES" all > "$out/build.log" 2>&1 || true
          {
            echo "| File | Result | First error |"
            echo "|---|---|---|"
            for f in util/*.c util/*.cc homa_receiver.cc; do
              o="util/$(basename "''${f%.*}").o"
              if [ -f "$o" ]; then
                echo "| $f | PASS | |"
              else
                # Rebuild it alone: with -j the errors interleave, and some are in headers.
                err=$(make -C util "$(basename "$o")" 2>&1 \
                  | grep -m 1 -E '^[^ ]+:[0-9]+:[0-9]+: error:' | sed 's/|/\\|/g' || true)
                echo "| $f | FAIL | $err |"
              fi
            done
            echo
            bins=$(make -s -C util -p -n all 2>/dev/null | sed -n 's/^BINS := //p')
            built=0
            for b in $bins; do [ -x "util/$b" ] && built=$((built + 1)); done
            echo "Programs built: $built of $(echo "$bins" | wc -w)"
          } > "$out/report.md"
        '' else ''
          make -C util -j"$NIX_BUILD_CORES" all
        ''}
        runHook postBuild
      '';

      dontInstall = report;
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

      meta = homaLib.meta // {
        description = "Homa user-space test/benchmark tools (util/)"
          + lib.optionalString debug " [ASan]";
      };
    };

  homa-utils = buildUtils { };
  homa-utils-debug = buildUtils { debug = true; };

  homa-tests = pkgs.stdenv.mkDerivation {
    pname = "homa-tests";
    inherit version;
    src = homaLib.src.test;

    # test/linux_objs (picks the vendored rbtree/rhashtable/xxhash for the kernel version)
    # is a #!/bin/bash script, which does not exist inside the build sandbox.
    postPatch = "patchShebangs test/linux_objs";

    nativeBuildInputs = [ pkgs.gnumake pkgs.perl pkgs.bash ];
    hardeningDisable = [ "all" ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      # unitKdir merges nixpkgs' split source/ + build/ trees and adapts the kernel
      # config to the mock layer (see nix/kernel/unit-kdir/default.nix).
      make -C test \
        KDIR=${unitKdir} \
        CC="gcc ${unitKdir.extraCFlags}" \
        -j"$NIX_BUILD_CORES" unit
      runHook postBuild
    '';

    # Run the unit tests as the check step (default IPv6 path).
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      (cd test && ./unit)
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      install -m755 test/unit "$out/bin/homa-unit"
      runHook postInstall
    '';

    meta = homaLib.meta // {
      description = "Homa kselftest-style unit tests (built + run under AddressSanitizer)";
    };
  };

  # The same unit tests built with gcov, run once; gcovr then reports line, branch and
  # function coverage of Homa's own sources (not the tests or the mock layer):
  #   unit.log      the test run
  #   lines.txt, summary.txt   line and branch coverage per file, plus the total
  #   coverage.json the totals, for scripts (homa-evidence)
  #   html/         per-line annotated source
  homa-tests-coverage = homa-tests.overrideAttrs (old: {
    pname = "homa-tests-coverage";
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.gcovr ];
    env = {
      NIX_CFLAGS_COMPILE = "--coverage";
      NIX_CFLAGS_LINK = "--coverage";
    };
    # Keep the run's output: its last lines count the tests that passed.
    checkPhase = ''
      runHook preCheck
      (cd test && ./unit) 2>&1 | tee unit.log
      grep -q '^\[  PASSED  \]' unit.log
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/html"
      cp unit.log "$out/"
      # Homa's sources are at the top of the tree, the harness in test/.
      gcov=(--gcov-executable "${lib.getBin pkgs.stdenv.cc.cc}/bin/gcov" --root .
        --filter '^(homa_[a-z_]+|timetrace)\.[ch]$' --exclude-unreachable-branches)
      gcovr "''${gcov[@]}" --txt "$out/summary.txt" --txt-metric branch \
        --json-summary "$out/coverage.json" --html-details "$out/html/index.html" \
        test
      gcovr "''${gcov[@]}" --txt "$out/lines.txt" test
      cat "$out/lines.txt"
      runHook postInstall
    '';
    meta = homaLib.meta // {
      description = "Line and branch coverage of Homa's sources by the unit tests";
    };
  });
in
{
  inherit buildUtils homa-utils homa-utils-debug;
  packages = { inherit homa-utils homa-utils-debug homa-tests homa-tests-coverage; };
}
