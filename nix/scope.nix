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
  # Homa's source with any forward-port patches in patches/ applied (currently none).
  # Every derivation builds this, not the flake's own tree. Files take it as `src`,
  # passed explicitly: nixpkgs has a package named src, which callPackage would pick.
  homaSrc = self.callPackage ./patches { src = inputs.self; };

  # Foundation: the kernels, kernel trees from source, tool lists, dev environment.
  kernelConfig = self.callPackage ./kernel.nix { };
  kernelSrc = self.callPackage ./kernel-src.nix { };
  packagesModule = self.callPackage ./packages.nix {
    inherit (self.kernelConfig) kernelPackages;
  };
  inherit (self.packagesModule) pythonEnv;
  envVars = self.callPackage ./env-vars.nix { };
  shellFunctions = self.callPackage ./shell-functions { };

  # Each of these returns { packages, checks?, ... } for a part in parts/.
  modulePkgs = self.callPackage ./module.nix { src = self.homaSrc; };
  crossPkgs = self.callPackage ./cross.nix {
    src = self.homaSrc;
    inherit (self.modulePkgs) buildAgainstTree;
  };
  userspacePkgs = self.callPackage ./userspace.nix { src = self.homaSrc; };
  ociPkgs = self.callPackage ./oci.nix {
    inherit (self.userspacePkgs) homa-utils homa-utils-debug;
  };
  analysisPkgs = self.callPackage ./analysis { src = self.homaSrc; };
  fuzzPkgs = self.callPackage ./fuzz { src = self.homaSrc; };
  microvmPkgs = self.callPackage ./microvms {
    inherit (inputs) microvm nixpkgs;
    buildSystem = pkgs.stdenv.hostPlatform.system;
    inherit (self.modulePkgs) buildModule;
    homaUtils = self.userspacePkgs.homa-utils;
  };
  devShell = self.callPackage ./devshell.nix { };
})
