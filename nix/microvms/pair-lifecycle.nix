# nix/microvms/pair-lifecycle.nix
#
# Pair lifecycle test (PLAN-pairs.md phase 4): the two-VM pair (node0 server, node1 client,
# on a private eth1 link) driven from the host over each guest's hvc0, with every phase
# timed. Neither guest runs a test of its own. The driver is tcl/bin/pair-lifecycle.tcl
# (Tcl/Expect, see tcl/README.md); this file only gives it its configuration.
#
#   1-3   start, serial, virtio     each node
#   4     insmod                    each node
#   5     link                      node1 pings node0 over eth1
#   6     servers                   demo_server1 and cp_node Homa/TCP servers on node0
#   7     traffic baseline          from node1: echo (demo_client1, 100 B .. 1 MB, six RPCs),
#                                   cp_node Homa, cp_node TCP; counter deltas on both nodes
#   8.i   netem <name>              tc netem on eth1 of both nodes (constants.lifecycle.netem),
#         traffic <name>            then the same traffic, which must still complete. Each
#                                   node's measured netem drop rate must match the configured
#                                   loss (no tail drops: every qdisc has limit >= 100000), and
#                                   with loss, Homa must have sent RESENDs
#   9     netem clear, traffic recovered
#   10    qdisc homa                Homa's qdisc on eth1 of both nodes (qdisc.nix), traffic
#                                   through it (TCP must pass the qdisc). virtio-net reports
#                                   no link speed (round-4 candidate 5)
#   11    qdisc paced               net.homa.link_mbps lowered so the pacer must defer and
#                                   send packets; traffic
#   12    qdisc off                 link_mbps restored, default qdisc back
#   13    stop servers
#   14    rmmod                     each node
#   15-18 dmesg, shutdown, exit, serial-log   each node
#
# The phase table is printed and written to summary.md; the last line is the VERDICT. Logs
# are in $HOMA_VM_LOGDIR (default: a fresh mktemp -d): node0/ and node1/ (each the working
# directory of its qemu, with serial.log), and traffic/<name>/ per traffic run.

{ lib
, constants
, tclApps         # tcl.nix
, serverRunner    # declaredRunner: pairNode = "server", consolePorts = ports.node0
, clientRunner    # declaredRunner: pairNode = "client", consolePorts = ports.node1
, ports           # { node0 = { serial; virtio; }; node1 = { serial; virtio; }; }
, metrics         # metrics.nix: expMetrics are the counters each traffic phase reports
, label ? ""
}:

let
  lc = constants.lifecycle;
  pair = constants.pair;
  netem = lc.netem;
  netemArgs = p: lib.optionalString (p.delay != null) "delay ${p.delay} "
    + "loss ${p.loss}% limit ${toString netem.limit}";
in
# Shallower queues would let netem tail-drop under load and count it as link loss.
assert netem.limit >= 100000;
tclApps.mkTclApp {
  name = "homa-pair-lifecycle${label}";
  driver = "pair-lifecycle.tcl";
  config = {
    inherit label;
    inherit (lc) timeouts;
    inherit (lc.qdisc) pacedMbps;
    peer = pair.nodes.server.ip;
    metrics = metrics.expMetrics;
    cpNode = {
      inherit (pair) workload gbps;
      seconds = pair.loadSeconds;
      homaPort = pair.cpNodeHomaPort;
    };
    netem = {
      inherit (netem) limit;
      phases = map (p: { inherit (p) name loss; args = netemArgs p; }) netem.phases;
    };
    node0 = ports.node0 // { runner = "${serverRunner}"; };
    node1 = ports.node1 // { runner = "${clientRunner}"; };
  };
}
