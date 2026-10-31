# nix/dev/packages.nix
#
# The dev shell's tools, grouped by role:
#   pythonEnv     python3 + the only third-party deps Homa's scripts use
#   allPackages   everything, for the dev shell
#
# In the scope (nix/scope.nix) as packagesModule.

{ pkgs
, lib
, kernelPackages
}:

let
  # Homa's Python tooling imports only matplotlib and numpy beyond the stdlib.
  pythonEnv = pkgs.python3.withPackages (p: [ p.matplotlib p.numpy ]);

  # Out-of-tree kernel module build dependencies (the key kbuild idiom) + make/perl for the
  # test harness dependency generation (test/mergedep.pl).
  buildTools = [
    pkgs.gnumake
    pkgs.perl
    pkgs.bc
  ] ++ kernelPackages.kernel.moduleBuildDependencies;

  # C/C++ static-analysis + formatting tools. `smatch` is not in every nixpkgs, so guard it.
  cTools = [
    pkgs.clang-tools # clang-tidy, clang-format
    pkgs.cppcheck
    pkgs.sparse
    pkgs.bear # compile_commands.json generation
    pkgs.gdb
  ] ++ lib.optional (pkgs ? smatch) pkgs.smatch;

  pyTools = [ pkgs.ruff pkgs.mypy pythonEnv ];
  shTools = [ pkgs.shellcheck pkgs.shfmt ];
  docTools = [ pkgs.groff pkgs.ghostscript ]; # man/ PDF generation
in
{
  inherit pythonEnv;
  allPackages = buildTools ++ cTools ++ pyTools ++ shTools ++ docTools;
}
