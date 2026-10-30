# nix/parts/scope.nix
#
# Builds the Homa package scope (../scope.nix) once per system and hands it to every other
# part as the perSystem argument `homa`.

{ inputs, ... }:

{
  perSystem = { pkgs, ... }: {
    _module.args.homa = import ../scope.nix { inherit pkgs inputs; };
  };
}
