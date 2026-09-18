# nix/fuzz/tools/fuzz.nix
#
# Builds the KERNEL-INDEPENDENT libFuzzer harnesses (Focus C: the standalone wire-format
# spec decoder, plus the self-test canary) and a `run-fuzzers` wrapper. These need no kernel
# headers, so `nix build .#fuzz` always works and `.#fuzz-run` always produces a real report.
# The deeper kernel-mock harnesses (Focus A/B) are built by fuzz-mock.nix.
#
# Pattern adapted from rocm-systems: -fsanitize=fuzzer,address,undefined, hardeningDisable,
# summary.txt/count.txt output, symbolized reproducers.

{ pkgs, lib, src }:

let
  sanFlags = "-std=c++17 -g -O1 -fno-omit-frame-pointer -fsanitize=fuzzer,address,undefined";
  symbolizer = "${lib.getBin pkgs.llvm}/bin/llvm-symbolizer";

  # Harnesses that compile with plain clang++ and no external headers.
  standaloneNames = [ "fuzz_selftest" "fuzz_dissector" ];

  runSeconds = 20;

  fuzz = pkgs.stdenv.mkDerivation {
    pname = "homa-fuzzers";
    version = "0";
    inherit src;
    nativeBuildInputs = [ pkgs.clang ];
    hardeningDisable = [ "all" ];
    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      mkdir -p out/bin out/corpus
      H=nix/fuzz/harness
      for name in ${lib.concatStringsSep " " standaloneNames}; do
        echo "Building $name ..."
        srcfile="$H/$name.cc"
        [ -f "$srcfile" ] || srcfile="$H/dissector/$name.cc"
        clang++ ${sanFlags} -I "$H" "$srcfile" -o "out/bin/$name"
        # Seed corpus (map fuzz_dissector -> corpus-seeds/dissector, else empty).
        seed="nix/fuzz/corpus-seeds/''${name#fuzz_}"
        mkdir -p "out/corpus/$name"
        [ -d "$seed" ] && cp "$seed"/* "out/corpus/$name/" 2>/dev/null || true
      done

      # run-fuzzers wrapper: FUZZ_TIME / FUZZ_WORKDIR env knobs.
      cat > out/bin/run-fuzzers <<'WRAP'
      #!/usr/bin/env bash
      set -uo pipefail
      root="$(cd "$(dirname "$0")/.." && pwd)"
      time="''${FUZZ_TIME:-60}"
      workdir="''${FUZZ_WORKDIR:-$(mktemp -d)}"
      export ASAN_SYMBOLIZER_PATH="@SYMBOLIZER@"
      export ASAN_OPTIONS="abort_on_error=0:detect_leaks=0:symbolize=1"
      total=0
      for bin in "$root"/bin/fuzz_*; do
        name="$(basename "$bin")"
        mkdir -p "$workdir/$name"
        "$bin" -max_total_time="$time" -artifact_prefix="$workdir/$name/" \
          "$workdir/$name" > "$workdir/$name.log" 2>&1 || true
        c=$(find "$workdir/$name" -name 'crash-*' 2>/dev/null | wc -l)
        printf '  %-20s %s crash(es)\n' "$name:" "$c"
        total=$((total + c))
      done
      echo "Total crash inputs: $total  (workdir: $workdir)"
      WRAP
      sed -i "s|@SYMBOLIZER@|${symbolizer}|" out/bin/run-fuzzers
      chmod +x out/bin/run-fuzzers
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -r out/* "$out/"
      runHook postInstall
    '';
    dontFixup = true;
  };

  # Bounded in-derivation run: build then fuzz each harness for runSeconds; collect crashes,
  # symbolize the first of each, write summary.txt + count.txt.
  fuzz-run = pkgs.stdenv.mkDerivation {
    pname = "homa-fuzz-run";
    version = "0";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.coreutils pkgs.findutils ];
    buildPhase = ''
      export ASAN_SYMBOLIZER_PATH="${symbolizer}"
      export ASAN_OPTIONS="abort_on_error=0:detect_leaks=0:symbolize=1"
      work="$PWD/work"; mkdir -p "$work"
      for bin in ${fuzz}/bin/fuzz_*; do
        name="$(basename "$bin")"
        mkdir -p "$work/$name"
        # seed the run with the committed corpus if present
        cp -r ${fuzz}/corpus/"$name"/* "$work/$name/" 2>/dev/null || true
        "$bin" -max_total_time=${toString runSeconds} \
          -artifact_prefix="$work/$name/" "$work/$name" \
          > "$work/$name.log" 2>&1 || true
      done
    '';
    installPhase = ''
      mkdir -p "$out" "$out/crashes"
      total=0
      {
        echo "=== Homa fuzz-run (${toString runSeconds}s per harness, standalone set) ==="
        for bin in ${fuzz}/bin/fuzz_*; do
          name="$(basename "$bin")"
          n=$(find "work/$name" -name 'crash-*' 2>/dev/null | wc -l)
          total=$((total + n))
          printf '  %-20s %s crash input(s)\n' "$name:" "$n"
          cp "work/$name.log" "$out/$name.log" 2>/dev/null || true
          first=$(find "work/$name" -name 'crash-*' 2>/dev/null | head -1)
          if [ -n "$first" ]; then
            mkdir -p "$out/crashes/$name"
            cp "work/$name"/crash-* "$out/crashes/$name/" 2>/dev/null || true
            ASAN_SYMBOLIZER_PATH="${symbolizer}" ASAN_OPTIONS="symbolize=1" \
              "$bin" "$first" > "$out/crashes/$name/repro.txt" 2>&1 || true
          fi
        done
        echo ""
        echo "Total crash inputs: $total"
      } > "$out/summary.txt"
      echo "$total" > "$out/count.txt"
      cat "$out/summary.txt"
    '';
    dontFixup = true;
  };
in
{
  inherit fuzz fuzz-run sanFlags symbolizer standaloneNames;
}
