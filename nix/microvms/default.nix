# nix/microvms/default.nix
#
# microVM assembly (uds-rdma-proxy pattern, one VM per kernel like xtcp2). Instantiates the
# guest (mkVm) and the orchestrator (lib) and exposes:
#   homa-microvm[-<series>]        the QEMU runner package (nix run boots it directly)
#   homa-microvm-test[-<series>]   boot, run smoke.nix in the guest (insmod, loopback echo
#                                  RPCs, rmmod), PASS/FAIL from the console log
#   homa-microvm-debug             default kernel with KASAN/KMEMLEAK
#   homa-microvm-test-debug        ... the same test under sanitizers
# <series> is every kernel.nix matrix entry (6_1 ... 7_3); the unsuffixed names use the
# default kernel. Tests share nothing on the host, so they can run in parallel.
#
# Usage in flake.nix:
#   microvmPkgs = import ./nix/microvms {
#     inherit pkgs lib microvm nixpkgs kernelConfig;
#     buildSystem = system;
#     buildModule = modulePkgs.buildModule;
#     homaUtils = userspacePkgs.homa-utils;
#   };

{ pkgs
, lib
, microvm
, nixpkgs
, kernelConfig
, buildSystem
, buildModule
, homaUtils
}:

let
  constants = import ./constants.nix { inherit lib; };

  mkGuest = { kernelPackages, withSanitizers ? false, autoTest ? false }: import ./mkVm.nix {
    inherit pkgs lib microvm nixpkgs buildSystem constants homaUtils
      kernelPackages withSanitizers autoTest;
    homaModule = buildModule { inherit kernelPackages; };
    homaModuleDebug = buildModule { inherit kernelPackages; enableDebug = true; };
  };

  mkTest = { kernelPackages, label, withSanitizers ? false }: import ./lib.nix {
    inherit pkgs lib constants label withSanitizers;
    runner = mkGuest { inherit kernelPackages withSanitizers; autoTest = true; };
  };

  defaultKp = kernelConfig.kernelPackages;

  perKernel = lib.concatMapAttrs
    (s: kp: {
      "homa-microvm-${s}" = mkGuest { kernelPackages = kp; };
      "homa-microvm-test-${s}" = mkTest { kernelPackages = kp; label = "-${s}"; };
    })
    kernelConfig.matrix;
in
{
  packages = {
    homa-microvm = mkGuest { kernelPackages = defaultKp; };
    homa-microvm-debug = mkGuest { kernelPackages = defaultKp; withSanitizers = true; };
    homa-microvm-test = mkTest { kernelPackages = defaultKp; label = ""; };
    homa-microvm-test-debug = mkTest {
      kernelPackages = defaultKp;
      label = "-debug";
      withSanitizers = true;
    };
  } // perKernel;
}
