# nix/fuzz/default.nix
#
# Fuzzing composition root (rocm-systems pattern). Focus on Homa's wire-format
# (de)serialization — see docs/DESIGN.md §7.
#
#   fuzz          standalone wire-decoder + selftest harnesses (kernel-free, always builds)
#   fuzz-run      bounded run of the standalone set -> summary.txt / count.txt / crashes
#   fuzz-deep     fork-mode + dictionary + crash dedup
#   fuzz-cov      llvm-cov of the wire decoder
#   fuzz-selftest canary gate (fails if the harness is vacuous)
#   fuzz-mock     kernel-mock harnesses (Focus A/B: per-type parse, dispatch, gro, roundtrip,
#                 differential) — kernel-header dependent, best-effort (reports what built)
#
# Usage in flake.nix:
#   fuzzPkgs = import ./nix/fuzz { inherit pkgs lib; src = self; };
#   # (kernelConfig is threaded in by flake.nix for the mock target)

{ pkgs
, lib
, src
, kernelConfig ? null
}:

let
  fuzzMod = import ./tools/fuzz.nix { inherit pkgs lib src; };
  inherit (fuzzMod) fuzz fuzz-run sanFlags symbolizer;

  fuzz-deep = import ./tools/fuzz-deep.nix { inherit pkgs lib src fuzz symbolizer; };
  fuzz-cov = import ./tools/fuzz-cov.nix { inherit pkgs lib src; };
  fuzz-selftest = import ./tools/fuzz-selftest.nix { inherit pkgs lib src sanFlags; };

  # Kernel-mock target only when a kernelConfig was provided.
  mockAttrs = lib.optionalAttrs (kernelConfig != null) {
    fuzz-mock = import ./tools/fuzz-mock.nix {
      inherit pkgs lib src kernelConfig sanFlags symbolizer;
    };
  };
in
{
  packages = {
    inherit fuzz fuzz-run fuzz-deep fuzz-cov fuzz-selftest;
  } // mockAttrs;

  # fuzz-selftest is a real gate and kernel-free, so it belongs in `nix flake check`.
  checks = { inherit fuzz-selftest; };
}
