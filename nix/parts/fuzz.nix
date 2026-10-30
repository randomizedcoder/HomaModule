# nix/parts/fuzz.nix
#
# The libFuzzer harnesses (../fuzz): fuzz-selftest is a check, the rest are packages.

{
  perSystem = { homa, ... }: {
    inherit (homa.fuzzPkgs) packages checks;
  };
}
