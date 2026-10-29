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

  mkGuest =
    { kernelPackages
    , withSanitizers ? false
    , autoTest ? false
    , pairNode ? null
    , pairPort ? constants.pair.socketPortBase
    }: import ./mkVm.nix {
      inherit pkgs lib microvm nixpkgs buildSystem constants homaUtils
        kernelPackages withSanitizers autoTest pairNode pairPort;
      homaModule = buildModule { inherit kernelPackages; };
      homaModuleDebug = buildModule { inherit kernelPackages; enableDebug = true; };
    };

  mkTest = { kernelPackages, label, withSanitizers ? false }: import ./lib.nix {
    inherit pkgs lib constants label withSanitizers;
    runner = mkGuest { inherit kernelPackages withSanitizers; autoTest = true; };
  };

  # Two-VM pair test: node0 (server) on serverKp, node1 (client) on clientKp.
  mkPairTest = { serverKp, clientKp, label, port }: import ./lib-pair.nix {
    inherit pkgs lib constants label port;
    serverRunner = mkGuest { kernelPackages = serverKp; autoTest = true; pairNode = "server"; pairPort = port; };
    clientRunner = mkGuest { kernelPackages = clientKp; autoTest = true; pairNode = "client"; pairPort = port; };
  };

  # Every ordered (server, client) pair of VM kernels: same-kernel pairs and both directions
  # of each mixed pair (wire compatibility between Homa builds for different kernels). Each
  # gets its own socket-link port (base + 1, + 2, ...), so they can all run at once; the
  # default homa-pair-test keeps the base port.
  vmSeries = lib.attrNames kernelConfig.vmMatrix;
  pairList = lib.concatMap (s: map (c: { server = s; client = c; }) vmSeries) vmSeries;
  perPair = lib.listToAttrs (lib.imap1
    (i: p: lib.nameValuePair "homa-pair-test-${p.server}-${p.client}" (mkPairTest {
      serverKp = kernelConfig.vmMatrix.${p.server};
      clientKp = kernelConfig.vmMatrix.${p.client};
      label = "-${p.server}-${p.client}";
      port = constants.pair.socketPortBase + i;
    }))
    pairList);

  defaultKp = kernelConfig.kernelPackages;

  perKernel = lib.concatMapAttrs
    (s: kp: {
      "homa-microvm-${s}" = mkGuest { kernelPackages = kp; };
      "homa-microvm-test-${s}" = mkTest { kernelPackages = kp; label = "-${s}"; };
    })
    kernelConfig.vmMatrix;
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
    homa-pair-test = mkPairTest {
      serverKp = defaultKp;
      clientKp = defaultKp;
      label = "";
      port = constants.pair.socketPortBase;
    };
  } // perKernel // perPair;
}
