# nix/fuzz/tools/fuzz-mock.nix
#
# Builds the KERNEL-MOCK libFuzzer harnesses (nix/fuzz/harness/mock/*.c). These feed fuzzer
# bytes through Homa's real receive path (homa_softirq -> homa_dispatch_pkts -> homa_*_pkt)
# on top of the unit-test mock layer (test/mock.c), compiled with clang + libFuzzer +
# ASan/UBSan against the same merged KDIR the unit tests use (nix/unit-kdir).
#
# The build logic lives in build-mock-fuzzers.sh so it can also be run by hand. This target
# is a gate: it fails unless every harness builds and runs its seed corpus cleanly.
#
# Output: $out/bin/<harness>, $out/corpus/ (generated seeds), $out/status.txt, and
# $out/bin/run-mock-fuzzers <seconds-per-harness> [outdir] for a time-boxed campaign.

{ pkgs, lib, src, kernelConfig, symbolizer }:

let
  unitKdir = import ../../unit-kdir { inherit pkgs lib kernelConfig; };

  runner = pkgs.writeShellScript "run-mock-fuzzers" ''
    # run-mock-fuzzers <seconds-per-harness> [outdir]
    set -u
    secs=''${1:-60}
    out=''${2:-mock-fuzz-out}
    here=$(dirname "$(readlink -f "$0")")
    export ASAN_SYMBOLIZER_PATH=${symbolizer}
    export UBSAN_OPTIONS=print_stacktrace=1
    mkdir -p "$out"
    : > "$out/summary.txt"
    for f in "$here"/fuzz_*; do
      name=$(basename "$f")
      mkdir -p "$out/$name/corpus" "$out/$name/crashes"
      cp -n "$here/../corpus"/* "$out/$name/corpus/" 2>/dev/null || true
      "$f" -max_total_time="$secs" -max_len=4096 -fork="$(nproc)" -ignore_crashes=1 \
        -artifact_prefix="$out/$name/crashes/" "$out/$name/corpus" \
        > "$out/$name/log.txt" 2>&1
      n=$(find "$out/$name/crashes" -type f | wc -l)
      cov=$(grep -o 'cov: [0-9]*' "$out/$name/log.txt" | tail -1)
      echo "$name $cov crashes: $n" | tee -a "$out/summary.txt"
    done
  '';
in
pkgs.stdenv.mkDerivation {
  pname = "homa-fuzzers-mock";
  version = "0";
  inherit src;
  nativeBuildInputs = [ pkgs.clang pkgs.llvmPackages.compiler-rt pkgs.python3 pkgs.bash ];
  hardeningDisable = [ "all" ];
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    patchShebangs test/linux_objs
    CC=clang CXX=clang++ JOBS=$NIX_BUILD_CORES \
      bash nix/fuzz/tools/build-mock-fuzzers.sh . ${unitKdir} out "${unitKdir.extraCFlags}"
    python3 nix/fuzz/tools/gen-mock-seeds.py out/corpus
    runHook postBuild
  '';

  # Smoke gate: every harness must get through the seeds with no sanitizer report and no
  # mock-layer leak, except findings already listed in nix/fuzz/known-findings.txt.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    known=$(grep -v '^#' nix/fuzz/known-findings.txt | grep .)
    for f in out/bin/fuzz_*; do
      name=$(basename "$f")
      if "$f" -runs=0 out/corpus > "smoke-$name.log" 2>&1; then
        echo "smoke: $name OK"
        continue
      fi
      summary=$(grep -m1 SUMMARY "smoke-$name.log" || true)
      if [ -n "$summary" ] && echo "$summary" | grep -qF "$known"; then
        echo "smoke: $name known finding: $summary"
      else
        cat "smoke-$name.log"
        echo "smoke: $name FAILED"
        exit 1
      fi
    done
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r out/bin out/corpus out/status.txt out/build.log "$out/"
    cp ${runner} "$out/bin/run-mock-fuzzers"
    runHook postInstall
  '';
  dontFixup = true;
}
