# nix/parts/evidence.nix
#
# One report of every check (../evidence): homa-evidence, and homa-evidence-full with the
# VM tests.

{
  perSystem = { homa, ... }: {
    inherit (homa.evidencePkgs) packages;
  };
}
