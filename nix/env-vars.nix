# nix/env-vars.nix
#
# A shell-script fragment (returned as a string) that the dev shell splices into its
# shellHook. Sets the environment Homa's Makefiles expect. Kept as a string so both the dev
# shell and any wrapper scripts can source the same definitions.
#
# Usage in flake.nix / devshell.nix:
#   envVars = import ./nix/env-vars.nix { inherit pkgs lib kernelConfig pythonEnv; };
#   # then, inside mkShell.shellHook:  ${envVars}

{ pkgs
, lib
, kernelConfig
, pythonEnv
}:

''
  # Homa's test/Makefile hardcodes x86 include paths.
  export ARCH="''${ARCH:-x86}"

  # Default KDIR to the flake-pinned kernel, but let callers override it (e.g. to build
  # against the running host kernel: make KDIR=/lib/modules/$(uname -r)/build).
  export KDIR="''${KDIR:-${kernelConfig.kdir}}"
  export LINUX_VERSION="''${LINUX_VERSION:-${kernelConfig.modDirVersion}}"

  # Headless matplotlib for the plotting scripts.
  export MPLBACKEND="''${MPLBACKEND:-Agg}"

  # Make the pinned python (with matplotlib/numpy) the one on PATH inside the shell.
  export PATH="${pythonEnv}/bin:$PATH"
''
