# nix/fuzz/default.nix
#
# Fuzzing composition root (rocm-systems pattern). Focus on Homa's wire-format
# (de)serialization — see docs/DESIGN.md §7.
#
#   fuzz          standalone wire-decoder + selftest harnesses (kernel-free, always builds),
#                 with bin/run-fuzzers (FUZZ_TIME=300 ./result/bin/run-fuzzers [outdir])
#   fuzz-run      a 20 s run of each of those -> summary.txt / count.txt / crashes
#   fuzz-deep     nix run .#fuzz-deep -- [outdir]: fork mode + dictionary, for as long as
#                 FUZZ_DEEP_TIME says
#   fuzz-cov      llvm-cov of the wire decoder
#   fuzz-selftest canary gate (fails if the harness is vacuous)
#   fuzz-mock     kernel-mock harnesses: real homa_softirq receive path + per-type pinned
#                 variants on the unit-test mock layer (gate: all build + seeds run clean),
#                 with bin/run-mock-fuzzers [seconds] [outdir]
#
# Every one of them runs harnesses through the same script, tools/run-fuzzers.sh, which
# also sorts the crashes by sanitizer signature.

{ pkgs
, lib
, homaLib
, unitKdir
}:

let
  src = homaLib.src.fuzz;
  sanFlags = "-std=c++17 -g -O1 -fno-omit-frame-pointer -fsanitize=fuzzer,address,undefined";
  symbolizer = "${lib.getBin pkgs.llvm}/bin/llvm-symbolizer";

  # homa-fuzz <bindir> <corpus> [outdir]: see tools/run-fuzzers.sh.
  runner = pkgs.writeShellApplication {
    name = "homa-fuzz";
    runtimeInputs = with pkgs; [ coreutils findutils gnugrep gnused ];
    runtimeEnv.ASAN_SYMBOLIZER_PATH = symbolizer;
    text = builtins.readFile ./tools/run-fuzzers.sh;
  };

  # A command for a build's bin/: runs the harnesses installed next to it, seeded from the
  # build's corpus/. setup runs first, and may set FUZZ_* and the arguments ("$@" is the
  # outdir).
  launcher = name: setup: pkgs.writeShellApplication {
    inherit name;
    text = ''
      here=$(dirname "$(readlink -f "$0")")
      ${setup}
      exec ${lib.getExe runner} "$here" "$here/../corpus" "$@"
    '';
  };

  # The clang++ command for one harness in nix/fuzz/harness.
  compileHarness = { name, out ? "out/bin/${name}", flags ? "" }:
    "clang++ ${sanFlags} ${flags} -I nix/fuzz/harness nix/fuzz/harness/${name}.cc -o ${out}";

  # A derivation over the fuzz sources, built with clang and no hardening flags (they clash
  # with the sanitizers).
  # A fuzz derivation: clang, then args' own nativeBuildInputs.
  mkFuzzDrv = args: pkgs.stdenv.mkDerivation ({
    version = "0";
    inherit src;
    hardeningDisable = [ "all" ];
    dontConfigure = true;
    dontFixup = true;
  } // args // {
    nativeBuildInputs = [ pkgs.clang ] ++ args.nativeBuildInputs or [ ];
  });

  # callPackageWith: like callPackage, with these added to what a file can name.
  call = file: lib.callPackageWith (pkgs // { inherit mkFuzzDrv compileHarness launcher unitKdir; })
    file
    { };

  # The kernel-independent harnesses: the standalone wire-format spec decoder and the
  # self-test canary. They need no kernel headers, so this always builds.
  standaloneNames = [ "fuzz_selftest" "fuzz_dissector" ];
  fuzz = mkFuzzDrv {
    pname = "homa-fuzzers";
    buildPhase = ''
      runHook preBuild
      mkdir -p out/bin out/corpus
      ${lib.concatMapStrings (name: ''
        ${compileHarness { inherit name; }}
        mkdir -p out/corpus/${name}
        cp nix/fuzz/corpus-seeds/${lib.removePrefix "fuzz_" name}/* out/corpus/${name}/ \
          2>/dev/null || true
      '') standaloneNames}
      cp ${launcher "run-fuzzers" ""}/bin/run-fuzzers out/bin/
      runHook postBuild
    '';
    installPhase = ''cp -r out "$out"'';
  };

  fuzz-run = pkgs.runCommand "homa-fuzz-run" { } ''
    FUZZ_TIME=20 ${lib.getExe runner} ${fuzz}/bin ${fuzz}/corpus "$out"
  '';

  # A command, not a build, so that its time limit can be set when it runs.
  fuzz-deep = pkgs.writeShellApplication {
    name = "fuzz-deep";
    text = ''
      # fuzz-deep [outdir]: FUZZ_DEEP_TIME (60 s per harness), FUZZ_DEEP_FORKS (2),
      # FUZZ_DEEP_MAXLEN (4096).
      export FUZZ_TIME=''${FUZZ_DEEP_TIME:-60} FUZZ_FORKS=''${FUZZ_DEEP_FORKS:-2} \
        FUZZ_MAXLEN=''${FUZZ_DEEP_MAXLEN:-4096} FUZZ_DICT=${src}/nix/fuzz/dict/homa_wire.dict
      exec ${lib.getExe runner} ${fuzz}/bin ${fuzz}/corpus "''${1:-fuzz-deep-out}"
    '';
  };

  fuzz-cov = call ./tools/fuzz-cov.nix;
  fuzz-selftest = call ./tools/fuzz-selftest.nix;
  fuzz-mock = call ./tools/fuzz-mock.nix;
in
{
  packages = { inherit fuzz fuzz-run fuzz-deep fuzz-cov fuzz-selftest fuzz-mock; };

  # fuzz-selftest is a real gate and kernel-free, so it belongs in `nix flake check`.
  checks = { inherit fuzz-selftest; };
}
