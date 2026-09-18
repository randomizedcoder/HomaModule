# nix/devshell.nix
#
# The Homa development shell. Composes the toolchain from packages.nix, the environment
# fragment from env-vars.nix, and the bash helper functions from shell-functions/*.nix.
#
# Usage in flake.nix:
#   devShells.default = import ./nix/devshell.nix {
#     inherit pkgs lib packagesModule envVars shellFunctions;
#   };

{ pkgs
, lib
, packagesModule
, envVars
  # Concatenated bash function definitions (from shell-functions/*.nix). Default "" so the
  # shell still works before Phase 4 wires them in.
, shellFunctions ? ""
}:

pkgs.mkShell {
  packages = packagesModule.allPackages;

  # Disable hardening in the shell so an in-shell `make` matches the derivations.
  hardeningDisable = [ "all" ];

  shellHook = ''
    ${envVars}
    ${shellFunctions}

    cat <<'EOF'
    Homa dev shell.  Kernel module + userspace + analysis toolchain is on PATH.

      homa-build          build homa.ko against $KDIR (override KDIR to retarget)
      homa-test           build and run the unit tests (ASan)
      homa-clean          make clean
      homa-checkpatch     run kernel checkpatch (needs a Linux source tree)
      homa-lint           quick static analysis (ruff + shellcheck + clang-format)

    Docs: nix/docs/DESIGN.md   Status: nix/docs/STATUS.md
    EOF
  '';
}
