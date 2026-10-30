# nix/patches/default.nix
#
# Upstream-pending fixes the flake needs in order to build Homa against its default kernel.
# Each patch is a fork draft PR's commit, exported with `git format-patch`. The list is empty
# while upstream `main` builds on the default kernel as-is (the 7.1 port, fork draft #12, landed
# upstream as e65a5c0 on 2026-10-27).
#
# homaLib (../lib) applies them to every source subset, each patch cut down to the files in
# that subset. Once upstream `main` carries a fix, its patch stops applying and the build
# fails at patchPhase: that is the cue to delete it from this list.

[ ]
