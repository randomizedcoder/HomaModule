# nix/fuzz/tools/fuzz-mock.nix
#
# Builds the KERNEL-MOCK libFuzzer harnesses (nix/fuzz/harness/mock/*.c). These feed fuzzer
# bytes through Homa's real receive path (homa_softirq -> homa_dispatch_pkts -> homa_*_pkt)
# on top of the unit-test mock layer (test/mock.c), compiled with clang + libFuzzer +
# ASan/UBSan against the same merged KDIR the unit tests use (nix/kernel/unit-kdir).
#
# The build logic lives in build-mock-fuzzers.sh so it can also be run by hand. This target
# is a gate: it fails unless every harness builds and runs its seed corpus cleanly.
#
# Output: $out/bin/<harness>, $out/corpus/ (generated seeds), $out/status.txt, and
# $out/bin/run-mock-fuzzers [seconds-per-harness] [outdir] for a time-boxed campaign (fork mode,
# one job per core).

{ pkgs, unitKdir, mkFuzzDrv, launcher }:

let
  runner = launcher "run-mock-fuzzers" ''
    FUZZ_TIME=''${1:-60}
    FUZZ_FORKS=''${FUZZ_FORKS:-$(nproc)}
    export FUZZ_TIME FUZZ_FORKS FUZZ_MAXLEN=4096
    set -- "''${2:-mock-fuzz-out}"
  '';
in
mkFuzzDrv {
  pname = "homa-fuzzers-mock";
  nativeBuildInputs = [ pkgs.clang pkgs.llvmPackages.compiler-rt pkgs.python3 pkgs.bash ];

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
    known=$(grep -v '^#' nix/fuzz/known-findings.txt | grep . || true)
    for f in out/bin/fuzz_*; do
      name=$(basename "$f")
      if "$f" -runs=0 out/corpus > "smoke-$name.log" 2>&1; then
        echo "smoke: $name OK"
        continue
      fi
      summary=$(grep -m1 SUMMARY "smoke-$name.log" || true)
      if [ -n "$summary" ] && [ -n "$known" ] && echo "$summary" | grep -qF "$known"; then
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
    cp ${runner}/bin/run-mock-fuzzers "$out/bin/"
    runHook postInstall
  '';
}
