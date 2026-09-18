# nix/microvms/default.nix
#
# microVM assembly (uds-rdma-proxy pattern). Instantiates the guest (mkVm) and the
# orchestrator (lib) for the normal and debug (KASAN) flavours, and exposes:
#   homa-microvm            the QEMU runner package (nix run boots it directly)
#   homa-microvm-debug      ... with a KASAN/KMEMLEAK kernel
#   homa-microvm-test       boot + insmod homa.ko + smoke test, verdict PASS/FAIL
#   homa-microvm-test-debug ... under sanitizers
#
# Usage in flake.nix:
#   microvmPkgs = import ./nix/microvms {
#     inherit pkgs lib microvm nixpkgs kernelConfig;
#     buildSystem = system;
#     homaModule = modulePkgs.homa-module;
#     homaModuleDebug = modulePkgs.homa-module-debug;
#   };

{ pkgs
, lib
, microvm
, nixpkgs
, kernelConfig
, buildSystem
, homaModule
, homaModuleDebug
, homaUtils ? null
}:

let
  constants = import ./constants.nix { inherit lib; };

  mkGuest = withSanitizers: import ./mkVm.nix {
    inherit pkgs lib microvm nixpkgs kernelConfig buildSystem constants
      homaModule homaModuleDebug homaUtils withSanitizers;
  };

  guest = mkGuest false;
  guestDebug = mkGuest true;

  test = import ./lib.nix {
    inherit pkgs lib constants;
    runner = guest;
    label = "";
    withSanitizers = false;
  };
  testDebug = import ./lib.nix {
    inherit pkgs lib constants;
    runner = guestDebug;
    label = "-debug";
    withSanitizers = true;
  };
in
{
  packages = {
    homa-microvm = guest;
    homa-microvm-debug = guestDebug;
    homa-microvm-test = test;
    homa-microvm-test-debug = testDebug;
  };
}
