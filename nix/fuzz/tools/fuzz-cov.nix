# nix/fuzz/tools/fuzz-cov.nix
#
# Source-based coverage of the standalone wire decoder (fuzz_dissector), replayed over its
# corpus, reported with llvm-cov. Gives a concrete coverage number for the wire
# (de)serialization decode logic. Kernel-free.

{ pkgs, mkFuzzDrv, compileHarness }:

mkFuzzDrv {
  pname = "homa-fuzz-cov";
  nativeBuildInputs = [ pkgs.llvm ];

  buildPhase = ''
    runHook preBuild
    mkdir -p "$out"
    ${compileHarness {
      name = "fuzz_dissector";
      out = "fuzz_dissector_cov";
      flags = "-fprofile-instr-generate -fcoverage-mapping";
    }}

    work="$PWD/work"; mkdir -p "$work"
    cp nix/fuzz/corpus-seeds/dissector/* "$work/" 2>/dev/null || true
    LLVM_PROFILE_FILE="$PWD/dissector.profraw" \
      ./fuzz_dissector_cov -runs=200000 -max_total_time=20 "$work" > "$out/cov.log" 2>&1 || true

    llvm-profdata merge -sparse dissector.profraw -o dissector.profdata 2>/dev/null || true
    {
      echo "# fuzz-cov: coverage of the Homa wire decoder (fuzz_dissector)"
      llvm-cov report ./fuzz_dissector_cov -instr-profile=dissector.profdata 2>&1 || true
    } > "$out/summary.txt"
    llvm-cov show ./fuzz_dissector_cov -instr-profile=dissector.profdata \
      > "$out/dissector.show.txt" 2>&1 || true
    cp dissector.profdata "$out/" 2>/dev/null || true
    tail -n 20 "$out/summary.txt"
    runHook postBuild
  '';

  dontInstall = true;
}
