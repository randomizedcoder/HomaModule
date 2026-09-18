# nix/fuzz/tools/fuzz-cov.nix
#
# Source-based coverage of the standalone wire decoder (fuzz_dissector), replayed over its
# corpus, reported with llvm-cov. Gives a concrete coverage number for the wire
# (de)serialization decode logic. Kernel-free.

{ pkgs, lib, src }:

pkgs.stdenv.mkDerivation {
  pname = "homa-fuzz-cov";
  version = "0";
  inherit src;
  nativeBuildInputs = [ pkgs.clang pkgs.llvm ];
  hardeningDisable = [ "all" ];
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    H=nix/fuzz/harness
    mkdir -p "$out"
    clang++ -std=c++17 -g -O1 -fsanitize=fuzzer,address,undefined \
      -fprofile-instr-generate -fcoverage-mapping \
      -I "$H" "$H/fuzz_dissector.cc" -o fuzz_dissector_cov

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
    echo "0" > "$out/count.txt"
    tail -n 20 "$out/summary.txt"
    runHook postBuild
  '';

  installPhase = "true";
  dontFixup = true;
}
