# nix/patches/default.nix
#
# Upstream-pending fixes the flake needs in order to build Homa against its default kernel.
# Each patch is a fork draft PR's commit, exported with `git format-patch`. The list is empty
# while upstream `main` builds on the default kernel as-is (the 7.1 port, fork draft #12, landed
# upstream as e65a5c0 on 2026-10-27).
#
# Once upstream `main` carries a fix, its patch stops applying and the build fails at
# patchPhase: that is the cue to delete it from this list.
#
# Usage in flake.nix:
#   homaSrc = import ./nix/patches { inherit pkgs; src = self; };

{ pkgs, src }:

(pkgs.applyPatches {
  name = "homa-src";
  inherit src;
  patches = [ ];
})
  # Keep the flake's revision visible for version strings (src.rev in module.nix etc.).
  // { rev = src.rev or "dirty"; }
