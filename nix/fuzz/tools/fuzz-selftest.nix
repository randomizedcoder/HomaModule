# nix/fuzz/tools/fuzz-selftest.nix
#
# Canary gate (rocm-systems idea): compile fuzz_selftest with the copy bound deliberately
# widened past the 8-byte guarded buffer, feed it an overflowing input, and REQUIRE that it
# aborts (via the fuzz_guard canary or ASan). If it does not, the harness/toolchain is
# vacuous and this build fails. This is the one fuzz target that is a real pass/fail gate.

{ pkgs, lib, src, sanFlags }:

pkgs.stdenv.mkDerivation {
  pname = "homa-fuzz-selftest";
  version = "0";
  inherit src;
  nativeBuildInputs = [ pkgs.clang ];
  hardeningDisable = [ "all" ];
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    H=nix/fuzz/harness
    mkdir -p "$out"
    # Inject the regression: widen the copy to 32 bytes into an 8-byte buffer.
    clang++ ${sanFlags} -DSELFTEST_COPY_LEN=32 -I "$H" "$H/fuzz_selftest.cc" -o selftest_broken
    head -c 32 /dev/zero | tr '\0' 'A' > overflow.bin

    set +e
    ASAN_OPTIONS=abort_on_error=1 ./selftest_broken overflow.bin > "$out/selftest.log" 2>&1
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
      echo "SELFTEST FAILED: harness did NOT catch the injected overflow" | tee "$out/verdict.txt" >&2
      exit 1
    fi
    if grep -qiE 'canary smashed|AddressSanitizer|stack-buffer-overflow|global-buffer-overflow' "$out/selftest.log"; then
      echo "SELFTEST PASS: injected overflow detected (rc=$rc)" | tee "$out/verdict.txt"
    else
      echo "SELFTEST FAILED: process aborted (rc=$rc) but no overflow signature found" | tee "$out/verdict.txt" >&2
      exit 1
    fi
    runHook postBuild
  '';

  installPhase = "true";
  dontFixup = true;
}
