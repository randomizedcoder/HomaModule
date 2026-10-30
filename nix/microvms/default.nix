# nix/microvms/default.nix
#
# microVM assembly (uds-rdma-proxy pattern, one VM per kernel like xtcp2). Instantiates the
# guest (mkVm) and the orchestrator (lib) and exposes:
#   homa-microvm[-<series>]        the QEMU runner package (nix run boots it directly)
#   homa-microvm-test[-<series>]   boot, run smoke.nix in the guest (insmod, loopback echo
#                                  RPCs, rmmod), PASS/FAIL from the console log
#   homa-lifecycle[-<series>]      host-driven phases over ttyS0 + a virtio console, each
#                                  timed: boot, smoke, module cycles, dmesg, poweroff, exit
#                                  (lifecycle.nix, pcp pattern)
#   homa-microvm-debug             default kernel with KASAN/KMEMLEAK
#   homa-microvm-test-debug        ... the same test under sanitizers
#   homa-pair-test[-<s>-<c>]       two VMs (lib-pair.nix): Homa between server <s>, client <c>
#   homa-pair-exp[-socket]         latency sweep over the pair link (STATUS.md F2)
#   homa-vm-matrix                 every homa-microvm-test-<series> and pair, in parallel,
#                                  with a summary table (matrix.nix)
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
    , pairExperiments ? null
    , pairLink ? "dgram"
    , consolePorts ? null
    }: import ./mkVm.nix {
      inherit pkgs lib microvm nixpkgs buildSystem constants homaUtils
        kernelPackages withSanitizers autoTest pairNode pairPort pairExperiments pairLink
        consolePorts;
      homaModule = buildModule { inherit kernelPackages; };
      homaModuleDebug = buildModule { inherit kernelPackages; enableDebug = true; };
    };

  mkTest = { kernelPackages, label, withSanitizers ? false }: import ./lib.nix {
    inherit pkgs lib constants label withSanitizers;
    runner = mkGuest { inherit kernelPackages withSanitizers; autoTest = true; };
  };

  # Lifecycle test; index picks the guest's console ports (constants.lifecycle).
  mkLifecycle = { kernelPackages, label, index }:
    let
      base = constants.lifecycle.portBase + 2 * index;
      consolePorts = { serial = base; virtio = base + 1; };
    in
    import ./lifecycle.nix {
      inherit pkgs lib constants label consolePorts;
      runner = mkGuest { inherit kernelPackages consolePorts; };
    };

  # Two-VM pair test: node0 (server) on serverKp, node1 (client) on clientKp.
  mkPairTest = { serverKp, clientKp, label, port, experiments ? null, link ? "dgram" }: import ./lib-pair.nix {
    inherit pkgs lib constants label port link;
    serverRunner = mkGuest {
      kernelPackages = serverKp;
      autoTest = true;
      pairNode = "server";
      pairPort = port;
      pairExperiments = experiments;
      pairLink = link;
    };
    clientRunner = mkGuest {
      kernelPackages = clientKp;
      autoTest = true;
      pairNode = "client";
      pairPort = port;
      pairExperiments = experiments;
      pairLink = link;
    };
  };

  # Sweep for STATUS.md F2 (Homa's P50 RTT over the VM link): one cp_node run per entry,
  # with the sysctls applied on both nodes.
  latencyExperiments =
    let
      homa = name: workload: sysctls: { inherit name workload sysctls; proto = "homa"; gbps = "0.2"; };
      tcp = name: workload: { inherit name workload; proto = "tcp"; gbps = "0.2"; sysctls = { }; };
    in
    [
      (homa "w4-default" "w4" { })
      (homa "w4-link1000" "w4" { link_mbps = 1000; })
      (homa "w4-link2000" "w4" { link_mbps = 2000; })
      (homa "w4-resend2" "w4" { resend_ticks = 2; })
      (homa "w4-resend10" "w4" { resend_ticks = 10; })
      (tcp "w4-tcp" "w4")
      (homa "w1-default" "w1" { })
      (homa "w1-link1000" "w1" { link_mbps = 1000; })
      (tcp "w1-tcp" "w1")
    ];

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

  # homa-vm-matrix: every per-kernel smoke and lifecycle test and every pair, in parallel.
  matrix = import ./matrix.nix {
    inherit pkgs lib;
    tests =
      lib.concatMap
        (s: map
          (kind: {
            name = "homa-${kind}-${s}";
            kernels = s;
            exe = perKernel."homa-${kind}-${s}";
          }) [ "microvm-test" "lifecycle" ])
        vmSeries
      ++ map
        (p: {
          name = "homa-pair-test-${p.server}-${p.client}";
          kernels = "${p.server} → ${p.client}";
          exe = perPair."homa-pair-test-${p.server}-${p.client}";
        })
        pairList;
  };

  perKernel = lib.foldl' (a: b: a // b) { } (lib.imap1
    (i: s:
      let kp = kernelConfig.vmMatrix.${s}; in {
        "homa-microvm-${s}" = mkGuest { kernelPackages = kp; };
        "homa-microvm-test-${s}" = mkTest { kernelPackages = kp; label = "-${s}"; };
        "homa-lifecycle-${s}" = mkLifecycle { kernelPackages = kp; label = "-${s}"; index = i; };
      })
    vmSeries);
in
{
  packages = {
    homa-microvm = mkGuest { kernelPackages = defaultKp; };
    homa-microvm-debug = mkGuest { kernelPackages = defaultKp; withSanitizers = true; };
    homa-microvm-test = mkTest { kernelPackages = defaultKp; label = ""; };
    homa-lifecycle = mkLifecycle { kernelPackages = defaultKp; label = ""; index = 0; };
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
    homa-pair-exp = mkPairTest {
      serverKp = defaultKp;
      clientKp = defaultKp;
      label = "-exp";
      port = constants.pair.socketPortBase + 50;
      experiments = latencyExperiments;
    };
    # The same sweep over QEMU's TCP stream backend, which adds the multi-millisecond
    # stalls of STATUS.md F2.
    homa-pair-exp-socket = mkPairTest {
      serverKp = defaultKp;
      clientKp = defaultKp;
      label = "-exp-socket";
      port = constants.pair.socketPortBase + 60;
      experiments = latencyExperiments;
      link = "socket";
    };
    homa-vm-matrix = matrix;
  } // perKernel // perPair;
}
