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
#   homa-pair-test[-<s>-<c>]       two VMs (pair-test.nix): Homa between server <s>, client <c>
#   homa-pair-lifecycle[-<series>] the pair driven over both consoles, with timed phases and
#                                  tc netem loss/delay phases (pair-lifecycle.nix)
#   homa-pair-exp[-socket]         latency sweep over the pair link (STATUS.md F2)
#   homa-vm-matrix                 every homa-microvm-test-<series> and pair, in parallel,
#                                  with a summary table (matrix.nix)
# <series> is every kernel/config.nix matrix entry (6_1 ... 7_3); the unsuffixed names use the
# default kernel. Tests share nothing on the host, so they can run in parallel.
#
# Called from nix/scope.nix. Host ports come from ports.nix, which fails evaluation if two
# tests would bind the same one.

{ pkgs
, lib
, homaLib
, microvm
, nixpkgs
, kernelConfig
, buildSystem
, buildModule
, homaUtils
}:

let
  constants = import ./constants.nix { inherit lib; };
  tclApps = import ./host/tcl.nix { inherit pkgs lib; inherit (constants) oopsRegex; };
  metrics = import ./guest/metrics.nix { inherit pkgs lib; };

  defaultKp = kernelConfig.kernelPackages;
  vmSeries = lib.attrNames kernelConfig.vmMatrix;

  # forKernels prefix f: prefix = f "default" <default kernel>, and prefix-<series> = f
  # <series> <its kernel> for every vmMatrix entry.
  forKernels = prefix: f:
    { ${prefix} = f "default" defaultKp; } // homaLib.perKernel prefix f kernelConfig.vmMatrix;
  labelOf = name: if name == "default" then "" else "-${name}";

  # Every ordered (server, client) pair of VM kernels: same-kernel pairs and both directions
  # of each mixed pair (wire compatibility between Homa builds for different kernels).
  pairList = lib.concatMap (s: map (c: { server = s; client = c; }) vmSeries) vmSeries;
  pairName = p: "${p.server}-${p.client}";

  ports = import ./ports.nix {
    inherit lib constants vmSeries;
    linkNames =
      [
        { name = "pair-test"; link = "dgram"; }
        { name = "pair-exp"; link = "dgram"; }
        { name = "pair-exp-socket"; link = "socket"; }
      ]
      ++ map (n: { name = "pair-lifecycle-${n}"; link = "dgram"; }) ([ "default" ] ++ vmSeries)
      ++ map (p: { name = "pair-test-${pairName p}"; link = "dgram"; }) pairList;
  };

  mkGuest =
    { kernelPackages
    , withSanitizers ? false
    , autoTest ? false
    , pairNode ? null
    , pairPort ? ports.link "pair-test"
    , pairExperiments ? null
    , pairLink ? "dgram"
    , consolePorts ? null
    }: import ./guest/mkVm.nix {
      inherit pkgs lib microvm nixpkgs buildSystem constants homaUtils
        kernelPackages withSanitizers autoTest pairNode pairPort pairExperiments pairLink
        consolePorts;
      homaModule = buildModule { inherit kernelPackages; };
      homaModuleDebug = buildModule { inherit kernelPackages; enableDebug = true; };
    };

  mkTest = { kernelPackages, label, withSanitizers ? false }: import ./host/smoke-test.nix {
    inherit pkgs lib constants label withSanitizers;
    runner = mkGuest { inherit kernelPackages withSanitizers; autoTest = true; };
  };

  # Lifecycle test of the kernel called name ("default" or a series).
  mkLifecycle = name: kernelPackages:
    let consolePorts = ports.console name; in
    import ./host/lifecycle.nix {
      inherit lib constants tclApps consolePorts;
      label = labelOf name;
      runner = mkGuest { inherit kernelPackages consolePorts; };
    };

  # Pair lifecycle (PLAN-pairs.md phase 4): both nodes on one kernel, driven over their
  # consoles, with netem phases.
  mkPairLifecycle = name: kernelPackages:
    let
      consoles = ports.pairConsoles name;
      node = pairNode: mkGuest {
        inherit kernelPackages pairNode;
        pairPort = ports.link "pair-lifecycle-${name}";
        consolePorts = consoles.${if pairNode == "server" then "node0" else "node1"};
      };
    in
    import ./host/pair-lifecycle.nix {
      inherit lib constants tclApps metrics;
      label = labelOf name;
      ports = consoles;
      serverRunner = node "server";
      clientRunner = node "client";
    };

  # Two-VM pair test: node0 (server) on serverKp, node1 (client) on clientKp.
  mkPairTest = { serverKp, clientKp, label, port, experiments ? null, link ? "dgram" }: import ./host/pair-test.nix {
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

  perPair = lib.listToAttrs (map
    (p: lib.nameValuePair "homa-pair-test-${pairName p}" (mkPairTest {
      serverKp = kernelConfig.vmMatrix.${p.server};
      clientKp = kernelConfig.vmMatrix.${p.client};
      label = "-${pairName p}";
      port = ports.link "pair-test-${pairName p}";
    }))
    pairList);

  perKernel =
    forKernels "homa-microvm" (_: kernelPackages: mkGuest { inherit kernelPackages; })
    // forKernels "homa-microvm-test" (name: kernelPackages: mkTest {
      inherit kernelPackages;
      label = labelOf name;
    })
    // forKernels "homa-lifecycle" mkLifecycle
    // forKernels "homa-pair-lifecycle" mkPairLifecycle;

  # homa-vm-matrix: every per-kernel smoke, lifecycle and pair lifecycle test and every
  # pair, in parallel.
  matrix = import ./host/matrix.nix {
    inherit lib tclApps;
    inherit (constants) echoRpcs;
    tests =
      lib.concatMap
        (s: map
          (kind: {
            name = "homa-${kind}-${s}";
            kernels = s;
            exe = perKernel."homa-${kind}-${s}";
          }) [ "microvm-test" "lifecycle" "pair-lifecycle" ])
        vmSeries
      ++ map
        (p: {
          name = "homa-pair-test-${pairName p}";
          kernels = "${p.server} → ${p.client}";
          exe = perPair."homa-pair-test-${pairName p}";
        })
        pairList;
  };
in
{
  packages = {
    homa-microvm-debug = mkGuest { kernelPackages = defaultKp; withSanitizers = true; };
    homa-microvm-test-debug = mkTest {
      kernelPackages = defaultKp;
      label = "-debug";
      withSanitizers = true;
    };
    homa-pair-test = mkPairTest {
      serverKp = defaultKp;
      clientKp = defaultKp;
      label = "";
      port = ports.link "pair-test";
    };
    homa-pair-exp = mkPairTest {
      serverKp = defaultKp;
      clientKp = defaultKp;
      label = "-exp";
      port = ports.link "pair-exp";
      experiments = latencyExperiments;
    };
    # The same sweep over QEMU's TCP stream backend, which adds the multi-millisecond
    # stalls of STATUS.md F2.
    homa-pair-exp-socket = mkPairTest {
      serverKp = defaultKp;
      clientKp = defaultKp;
      label = "-exp-socket";
      port = ports.link "pair-exp-socket";
      experiments = latencyExperiments;
      link = "socket";
    };
    homa-vm-matrix = matrix;
    # The Tcl drivers' tests and lint, for running by hand (tcl.nix, ../tcl/README.md).
    homa-tcl-test = tclApps.test;
    homa-tcl-lint = tclApps.lint;
  } // perKernel // perPair;

  # The Tcl drivers' tests and lint (tcl.nix).
  checks.tcl-tests = tclApps.tests;
}
