# nix/microvms/constants.nix
#
# Pure data shared by the guest builder (mkVm.nix) and the orchestrator (lib.nix). Single
# source of truth for identity, resources and timeouts (uds-rdma-proxy pattern).

{ lib }:

{
  hostname = "homa-vm";

  # Guest resources.
  vcpu = 2;
  mem = 2048; # MiB, normal build
  memDebug = 4096; # KASAN needs headroom

  # Whole-run timeouts (seconds): boot + smoke test + poweroff. The kernels are chosen in
  # kernel.nix (default and matrix), not here.
  bootTimeout = 300;
  bootTimeoutDebug = 1200; # KASAN guests boot slowly

  stateVersion = "24.11";

  # Two-VM pair test (pair.nix, lib-pair.nix; uds-rdma-proxy pattern). The guests share a
  # private L2 link on eth1: a QEMU socket netdev that node0 listens on and node1 connects
  # to, so no root, tap or bridge is needed. Hostnames follow cp_node's "node<N>" naming.
  pair = {
    nodes = {
      server = { hostname = "node0"; ip = "10.88.0.1"; mac = "52:54:00:88:00:01"; role = "listen"; };
      client = { hostname = "node1"; ip = "10.88.0.2"; mac = "52:54:00:88:00:02"; role = "connect"; };
    };
    prefixLength = 24;
    socketPortBase = 23700; # host 127.0.0.1 port for the QEMU socket link; +N per pair target

    # Guest TCP ports for coordination (not Homa traffic).
    readyPort = 5998; # server listens once its Homa servers are up
    donePort = 5999; # client sends its verdict here when finished
    cpNodeHomaPort = 4100; # demo_server1 already owns Homa port 4000

    # cp_node load phase: a few seconds of workload w4 at a modest rate (the socket link
    # runs at roughly 1-2 Gb/s; this shows traffic flows, not Homa's performance).
    workload = "w4";
    gbps = "0.2";
    loadSeconds = 6;

    serverTimeout = 120; # client waits this long for the server's ready port
    clientTimeout = 300; # server waits this long for the client's report
    runTimeout = 420; # host: whole pair run
  };
}
