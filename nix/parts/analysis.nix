# nix/parts/analysis.nix
#
# Static analysis (../analysis): analysis-quick is a check, the rest are packages.

{
  perSystem = { homa, ... }: {
    inherit (homa.analysisPkgs) packages checks;
  };
}
