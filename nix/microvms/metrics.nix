# nix/microvms/metrics.nix
#
# Counters for the pair tests: the homa-node-stats guest command, and the awk helpers that
# turn two of its outputs into "name=delta" lines. Shared by pair.nix (in the guest) and
# pair-lifecycle.nix (on the host, over the consoles).

{ pkgs, lib }:

rec {
  # Counters reported per run (Homa's summed over cores). Lost or late packets show up as
  # RESENDs and resent_packets; wait_block/fast/none show how receivers waited. The rest
  # say where a lost packet went: eth1 and virtio-net drops, qdisc drops, softnet backlog
  # drops, and TCP retransmits for the baseline runs.
  expMetrics = [
    "packets_sent_DATA"
    "packets_sent_GRANT"
    "packets_sent_RESEND"
    "packets_rcvd_RESEND"
    "packets_rcvd_DATA"
    "packets_rcvd_BUSY"
    "packets_sent_BUSY"
    "requests_received"
    "responses_received"
    "resent_packets_used"
    "unknown_rpcs"
    "malformed_packets"
    "data_xmit_errors"
    "control_xmit_errors"
    "handoffs_thread_waiting"
    "gro_data_bypasses"
    "linux_softirqd_actions"
    "resent_packets"
    "resent_discards"
    "rpc_timeouts"
    "packet_discards"
    "gaps_created"
    "dropped_data_no_bufs"
    "wait_none"
    "wait_fast"
    "wait_block"
    "eth1_rx_packets"
    "eth1_tx_packets"
    "eth1_rx_dropped"
    "eth1_tx_dropped"
    "virtio_drops"
    "qdisc_dropped"
    "softnet_dropped"
    "tcp_retrans"
  ];

  # Prints /proc/net/homa_metrics plus "name value" lines for the NIC and stack counters
  # above. Both guests share the host's /nix/store, so the client runs it on the server too.
  nodeStats = pkgs.writeShellApplication {
    name = "homa-node-stats";
    runtimeInputs = with pkgs; [ coreutils gawk iproute2 ethtool ];
    text = ''
      cat /proc/net/homa_metrics
      for f in rx_packets tx_packets rx_dropped tx_dropped; do
        echo "eth1_$f $(cat "/sys/class/net/eth1/statistics/$f")"
      done
      ethtool -S eth1 | awk '/drops:/ { s += $2 } END { print "virtio_drops", s + 0 }'
      tc -s qdisc show dev eth1 \
        | awk '$6 == "(dropped" { sub(",", "", $7); s += $7 } END { print "qdisc_dropped", s + 0 }'
      awk '{ s += strtonum("0x" $2) } END { print "softnet_dropped", s + 0 }' /proc/net/softnet_stat
      awk '$1 == "Tcp:" { if (!n) { for (i = 1; i <= NF; i++) c[$i] = i; n = 1 } else print "tcp_retrans", $c["RetransSegs"] }' /proc/net/snmp
    '';
  };

  # Bash functions: snap (homa-node-stats on stdin -> "name=value ...", summed over cores)
  # and delta <snap> <snap> (the non-zero differences).
  snapDelta = ''
    snap() {
      awk -v keys="${lib.concatStringsSep " " expMetrics}" '
        BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) want[k[i]] = 1 }
        ($1 in want) { sum[$1] += $2 }
        END { for (i = 1; i <= n; i++) printf "%s=%d ", k[i], sum[k[i]] + 0 }'
    }
    delta() {
      awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, x, " "); split(b, y, " ")
        for (i = 1; i <= n; i++) {
          split(x[i], p, "="); split(y[i], q, "=")
          if (q[2] - p[2] != 0) printf "%s=%d ", p[1], q[2] - p[2]
        }
      }'
    }
  '';
}
