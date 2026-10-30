# nix/scope.nix
#
# Every Homa derivation, in one package scope (lib.makeScope). Each file below is called
# with callPackage, which passes a file the arguments its argument list names: from this
# scope first, then from nixpkgs. A file states what it needs, and nothing has to thread
# pkgs, lib and kernelConfig through by hand. The flake-parts modules in parts/ read their
# outputs from here:
#
#   homa = import ./scope.nix { inherit pkgs inputs; };
#   homa.modulePkgs.homa-module
#
# To swap a piece (another kernel, say), override the scope: homa.overrideScope (final:
# prev: { kernelConfig = ...; }) rebuilds everything that depends on it.

{ pkgs, inputs }:

pkgs.lib.makeScope pkgs.newScope (self: {
  # homaLib (lib/): version, meta, the source subsets with patches/ applied, mkKbuild,
  # perKernel.
  homaLib = self.callPackage ./lib { };

  # Foundation: the kernels, kernel trees from source, tool lists, dev environment.
  kernelConfig = self.callPackage ./kernel/config.nix { };
  kernelSrc = self.callPackage ./kernel/src.nix { };
  packagesModule = self.callPackage ./dev/packages.nix {
    inherit (self.kernelConfig) kernelPackages;
  };
  inherit (self.packagesModule) pythonEnv;
  envVars = self.callPackage ./dev/env-vars.nix { };
  shellFunctions = self.callPackage ./dev/shell-functions { };
  # The merged kernel tree that the unit tests and the mock fuzzers build against.
  unitKdir = self.callPackage ./kernel/unit-kdir { };

  # Each of these returns { packages, checks?, ... } for a part in parts/.
  modulePkgs = self.callPackage ./build/module.nix { };
  crossPkgs = self.callPackage ./build/cross.nix {
    inherit (self.modulePkgs) buildAgainstTree;
  };
  userspacePkgs = self.callPackage ./build/userspace.nix { };
  ociPkgs = self.callPackage ./build/oci.nix {
    inherit (self.userspacePkgs) homa-utils homa-utils-debug;
  };
  analysisPkgs = self.callPackage ./analysis { };
  fuzzPkgs = self.callPackage ./fuzz { };
  microvmPkgs = self.callPackage ./microvms {
    inherit (inputs) microvm nixpkgs;
    buildSystem = pkgs.stdenv.hostPlatform.system;
    inherit (self.modulePkgs) buildModule;
    homaUtils = self.userspacePkgs.homa-utils;
  };
  devShell = self.callPackage ./dev/shell.nix { };
})
