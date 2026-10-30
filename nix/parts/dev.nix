# nix/parts/dev.nix
#
# `nix develop` and `nix fmt`.

{
  perSystem = { homa, pkgs, ... }: {
    devShells.default = homa.devShell;
    formatter = pkgs.nixpkgs-fmt;
  };
}
