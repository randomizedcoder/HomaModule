# nix/microvms/pair.nix
#
# In-guest scripts for the two-VM pair test (PLAN-pairs.md). Two guests share a private L2
# link (eth1, a QEMU socket netdev). Each runs one of these as a systemd oneshot, prints
# phase markers on the serial console, then powers off. The host (lib-pair.nix) greps both
# consoles.
#
#   server (node0): insmod -> demo_server1 + cp_node servers (Homa, TCP) -> open the "ready"
#     port -> wait for the client's report on the "done" port -> stop servers -> rmmod ->
#     dmesg gate -> HOMA_PAIR_SERVER_PASS | HOMA_PAIR_SERVER_FAIL:<phase>
#   client (node1): insmod -> ping node0 -> wait for the ready port -> echo 100 B..1 MB across
#     VMs -> cp_node Homa load -> cp_node TCP load (baseline) -> rmmod -> dmesg gate ->
#     report to node0 -> HOMA_PAIR_PASS | HOMA_PAIR_FAIL:<phase>
#
# The ready/done ports are plain TCP (socat), separate from Homa, so a Homa failure still
# lets the server shut down cleanly instead of waiting for the host timeout.

{ pkgs
, homaKoPath
, homaUtils
, pair              # constants.pair
}:

let
  server = pair.nodes.server;
  tools = with pkgs; [ kmod coreutils gnugrep gawk procps iproute2 iputils socat homaUtils ];

  # Shared helpers. $PFX is the marker prefix (HOMA_PAIR or HOMA_PAIR_SERVER).
  common = ''
    ok() { echo "''${PFX}_$1_OK"; }
    dmesg_gate() {
      if dmesg | grep -qE 'BUG:|Oops|WARNING:.*homa|general protection'; then
        dmesg | tail -n 40
        return 1
      fi
    }
    echo "''${PFX}_START host=$(cat /proc/sys/kernel/hostname) kernel=$(uname -r)"
  '';

  # One cp_node client run: prints the last stats line, fails unless RPCs completed.
  #   $1 = protocol (homa|tcp), remaining args are passed to cp_node
  cpNode = ''
    cp_node_run() {
      local proto=$1 out line kops
      shift
      out=$(timeout ${toString pair.loadSeconds} cp_node client --protocol "$proto" \
        --workload ${pair.workload} --gbps ${pair.gbps} --first-server 0 --server-nodes 1 \
        --id 1 "$@" 2>&1 || true)
      line=$(echo "$out" | grep ' clients: ' | tail -n 1)
      if [ -z "$line" ]; then
        echo "$out" | tail -n 20
        return 1
      fi
      echo "HOMA_PAIR_CPNODE_$proto $line"
      kops=$(echo "$line" | awk '{ for (i = 1; i <= NF; i++) if ($i == "clients:") print $(i + 1) }')
      awk -v k="$kops" 'BEGIN { exit !(k > 0) }'
    }
  '';
in
{
  server = pkgs.writeShellApplication {
    name = "homa-pair-server";
    runtimeInputs = tools;
    text = ''
      PFX=HOMA_PAIR_SERVER
      ${common}
      fail() {
        echo "HOMA_PAIR_SERVER_FAIL:$1"
        dmesg | tail -n 40
        exit 1
      }

      insmod ${homaKoPath} || fail INSMOD
      ok INSMOD

      demo_server1 > /tmp/demo_server1.log 2>&1 &
      cp_node server --protocol homa --first-port ${toString pair.cpNodeHomaPort} \
        > /tmp/cp_node_homa.log 2>&1 &
      cp_node server --protocol tcp > /tmp/cp_node_tcp.log 2>&1 &
      sleep 1
      for p in demo_server1 cp_node; do
        pgrep -x "$p" > /dev/null || fail "SERVERS_$p"
      done
      ok SERVERS

      # Tell the client we are ready (it polls this port), then block until it reports.
      socat TCP-LISTEN:${toString pair.readyPort},fork,reuseaddr /dev/null &
      echo HOMA_PAIR_SERVER_READY
      report=$(timeout ${toString pair.clientTimeout} \
        socat -u TCP-LISTEN:${toString pair.donePort},reuseaddr STDOUT || true)
      echo "HOMA_PAIR_SERVER_CLIENT_REPORT ''${report:-<none>}"

      pkill -x demo_server1 || true
      pkill -x cp_node || true
      pkill -x socat || true
      sleep 1

      grep -q '^homa ' /proc/modules || fail LSMOD
      rmmod homa || fail RMMOD
      ok RMMOD
      dmesg_gate || fail DMESG
      ok DMESG

      echo HOMA_PAIR_SERVER_PASS
    '';
  };

  client = pkgs.writeShellApplication {
    name = "homa-pair-client";
    runtimeInputs = tools;
    text = ''
      PFX=HOMA_PAIR
      ${common}
      ${cpNode}
      peer=${server.ip}

      # Every exit reports to the server so it can shut down without waiting.
      report() { echo "$1" | timeout 10 socat -u STDIN "TCP:$peer:${toString pair.donePort}" || true; }
      fail() {
        echo "HOMA_PAIR_FAIL:$1"
        dmesg | tail -n 40
        report "FAIL:$1"
        exit 1
      }

      insmod ${homaKoPath} || fail INSMOD
      ok INSMOD

      for _ in $(seq 60); do ping -c 1 -W 1 "$peer" > /dev/null 2>&1 && break; done
      ping -c 3 -W 2 "$peer" > /dev/null || fail PING
      ok PING

      for _ in $(seq ${toString pair.serverTimeout}); do
        timeout 2 socat -u /dev/null "TCP:$peer:${toString pair.readyPort}" 2> /dev/null && break
        sleep 1
      done
      timeout 2 socat -u /dev/null "TCP:$peer:${toString pair.readyPort}" || fail PEER_READY
      ok PEER_READY

      # Echo 100 B .. 1 MB: multi-packet messages and grants over virtio-net.
      before=$(grep -E '^(packets_sent_DATA|packets_rcvd_GRANT) ' /proc/net/homa_metrics \
        | awk '{ s += $2 } END { print s + 0 }')
      responses=$(timeout 30 demo_client1 "$peer" 4000 | grep -c '^Received response' || true)
      after=$(grep -E '^(packets_sent_DATA|packets_rcvd_GRANT) ' /proc/net/homa_metrics \
        | awk '{ s += $2 } END { print s + 0 }')
      echo "HOMA_PAIR_ECHO responses=$responses (want 6) data+grant packets=$((after - before))"
      [ "$responses" = 6 ] || fail ECHO
      ok ECHO

      cp_node_run homa --first-port ${toString pair.cpNodeHomaPort} || fail CPNODE_HOMA
      ok CPNODE_HOMA
      cp_node_run tcp || fail CPNODE_TCP
      ok CPNODE_TCP

      rmmod homa || fail RMMOD
      ok RMMOD
      dmesg_gate || fail DMESG
      ok DMESG

      report PASS
      echo HOMA_PAIR_PASS
    '';
  };
}
