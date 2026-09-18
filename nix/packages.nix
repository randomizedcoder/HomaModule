# nix/packages.nix
#
# Toolchain inventory, split by role (nixpkgs convention):
#   nativeBuildInputs - build-time tools (kernel module build deps, make, perl)
#   buildInputs       - runtime libraries linked into build products
#   devTools          - dev/analysis-only tools (linters, formatters, gdb)
#   pythonEnv         - python3 + the only third-party deps Homa's scripts use
#   allPackages       - everything, for the dev shell
#
# Usage in flake.nix:
#   packagesModule = import ./nix/packages.nix { inherit pkgs lib kernelPackages; };

{ pkgs
, lib
, kernelPackages
}:

let
  # Homa's Python tooling imports only matplotlib and numpy beyond the stdlib.
  pythonEnv = pkgs.python3.withPackages (p: [ p.matplotlib p.numpy ]);

  # Out-of-tree kernel module build dependencies (the key kbuild idiom) + make/perl for the
  # test harness dependency generation (test/mergedep.pl).
  nativeBuildInputs = [
    pkgs.gnumake
    pkgs.perl
    pkgs.bc
  ] ++ kernelPackages.kernel.moduleBuildDependencies;

  buildInputs = [ ];

  # C/C++ static-analysis + formatting tools. `smatch` is not in every nixpkgs, so guard it.
  cTools = [
    pkgs.clang-tools     # clang-tidy, clang-format
    pkgs.cppcheck
    pkgs.sparse
    pkgs.bear            # compile_commands.json generation
    pkgs.gdb
  ] ++ lib.optional (pkgs ? smatch) pkgs.smatch;

  pyTools = [ pkgs.ruff pkgs.mypy ];
  shTools = [ pkgs.shellcheck pkgs.shfmt ];
  docTools = [ pkgs.groff pkgs.ghostscript ];   # man/ PDF generation

  devTools = cTools ++ pyTools ++ shTools ++ docTools ++ [ pythonEnv ];

  allPackages = nativeBuildInputs ++ buildInputs ++ devTools;
in
{
  inherit nativeBuildInputs buildInputs devTools pythonEnv allPackages;
}
