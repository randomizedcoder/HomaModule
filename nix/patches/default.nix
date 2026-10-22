# nix/patches/default.nix
#
# Upstream-pending fixes the flake needs in order to build Homa against its default kernel.
# Each patch is a fork draft PR's commit, exported with `git format-patch`:
#
#   0001-build-on-linux-7.1-and-later.patch   fork draft #12 (recvmsg addr_len, rps_tag_ptr)
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
  patches = [
    ./0001-build-on-linux-7.1-and-later.patch
  ];
})
  # Keep the flake's revision visible for version strings (src.rev in module.nix etc.).
  // { rev = src.rev or "dirty"; }
