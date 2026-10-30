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

  # Lifecycle test (lifecycle.nix, pcp pattern): per-phase timeouts in seconds, and the host
  # TCP ports of each guest's consoles, serial (ttyS0) = portBase + 2i and virtio (hvc0) =
  # portBase + 2i + 1, where i is 0 for the default kernel and 1, 2, ... per vmMatrix entry.
  lifecycle = {
    portBase = 24700;
    timeouts = {
      start = 10; # qemu up and its console ports listening
      serial = 30; # first kernel line in serial.log
      virtio = 120; # a root shell answering on hvc0 (full boot)
      smoke = 180; # homa-smoke (smoke.nix), run over hvc0
      cycles = 90; # insmod / netns add+del / rmmod, several times
      command = 30; # any other single command
      exit = 60; # poweroff until qemu exits
      echo = 60; # demo_client1's six RPCs, also over a lossy link
    };
    moduleCycles = 5;

    # Pair lifecycle (pair-lifecycle.nix): pair j's consoles are pairConsoleBase + 4j ..
    # + 4j + 3 (node0 serial, virtio, node1 serial, virtio) and its link is
    # pair.socketPortBase + pairLinkOffset + j.
    pairConsoleBase = 24800;
    pairLinkOffset = 200;

    # Link impairment phases: tc netem on eth1 of both nodes (so both directions), each
    # followed by echo, cp_node Homa and cp_node TCP. loss is a percentage (a string, as tc
    # takes it). Every netem qdisc gets this limit (packets): deep enough that the queue
    # never overflows, so the only drops are the configured random loss, not tail drops
    # that would skew the results. pair-lifecycle.nix checks each node's measured drop
    # rate against the configured one.
    netem = {
      limit = 100000;
      phases = [
        { name = "delay1ms"; delay = "1ms"; loss = "0"; }
        { name = "loss0.1"; delay = null; loss = "0.1"; }
        { name = "loss1"; delay = null; loss = "1"; }
        { name = "loss1-delay1ms"; delay = "1ms"; loss = "1"; }
        { name = "loss5"; delay = null; loss = "5"; }
      ];
    };
  };

  # Two-VM pair test (pair.nix, lib-pair.nix; uds-rdma-proxy pattern). The guests share a
  # private L2 link on eth1: a QEMU "dgram" (UDP) netdev between two host ports, so no
  # root, tap or bridge is needed ("socket", a TCP stream, is kept for comparison; see
  # STATUS.md F2). Hostnames follow cp_node's "node<N>" naming.
  pair = {
    nodes = {
      server = { hostname = "node0"; ip = "10.88.0.1"; mac = "52:54:00:88:00:01"; role = "listen"; };
      client = { hostname = "node1"; ip = "10.88.0.2"; mac = "52:54:00:88:00:02"; role = "connect"; };
    };
    prefixLength = 24;
    socketPortBase = 23700; # host 127.0.0.1 port for the pair link; +N per pair target
    dgramPortOffset = 1000; # "dgram" link: node0 binds the pair's port, node1 this much higher

    # Guest TCP ports for coordination (not Homa traffic).
    readyPort = 5998; # server listens once its Homa servers are up
    donePort = 5999; # client sends its verdict here when finished
    ctlPort = 5997; # sweep mode only: server shell for sysctls/metrics (private link)
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
