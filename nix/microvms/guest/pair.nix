# nix/microvms/guest/pair.nix
#
# In-guest scripts for the two-VM pair test (PLAN-pairs.md). Two guests share a private L2
# link (eth1, a QEMU socket netdev). Each runs one of these as a systemd oneshot, prints
# phase markers on the serial console, then powers off. The host (pair-test.nix) greps both
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
#
# experiments != null turns the client into a sweep (STATUS.md F2): instead of the echo and
# load phases, it runs cp_node once per entry, with the entry's net.homa sysctls applied on
# BOTH nodes. To do that the server also runs a shell on the private link's control port
# (test VMs only). Each run prints one HOMA_EXP line with the RTTs and the deltas of the
# selected /proc/net/homa_metrics counters on each node.

{ pkgs
, lib
, homaKoPath
, homaUtils
, pair              # constants.pair
, oopsRegex         # constants.oopsRegex
, echoRpcs          # constants.echoRpcs
, experiments ? null  # null, or a list of { name, proto, workload, gbps, sysctls }
}:

let
  server = pair.nodes.server;
  tools = with pkgs; [ kmod coreutils gnugrep gawk procps iproute2 iputils socat homaUtils ];
  isExp = experiments != null;

  metrics = import ./metrics.nix { inherit pkgs lib; };
  stats = lib.getExe metrics.nodeStats;

  # Shared helpers. $PFX is the marker prefix (HOMA_PAIR or HOMA_PAIR_SERVER).
  common = ''
    ok() { echo "''${PFX}_$1_OK"; }
    dmesg_gate() {
      if dmesg | grep -qE '${oopsRegex}'; then
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
  # Client phases, normal mode: echo, then cp_node over Homa and over TCP.
  normalPhases = ''
    # Echo 100 B .. 1 MB: multi-packet messages and grants over virtio-net.
    before=$(grep -E '^(packets_sent_DATA|packets_rcvd_GRANT) ' /proc/net/homa_metrics \
      | awk '{ s += $2 } END { print s + 0 }')
    responses=$(timeout 30 demo_client1 "$peer" 4000 | grep -c '^Received response' || true)
    after=$(grep -E '^(packets_sent_DATA|packets_rcvd_GRANT) ' /proc/net/homa_metrics \
      | awk '{ s += $2 } END { print s + 0 }')
    echo "HOMA_PAIR_ECHO responses=$responses (want ${toString echoRpcs}) data+grant packets=$((after - before))"
    [ "$responses" = ${toString echoRpcs} ] || fail ECHO
    ok ECHO

    cp_node_run homa --first-port ${toString pair.cpNodeHomaPort} || fail CPNODE_HOMA
    ok CPNODE_HOMA
    cp_node_run tcp || fail CPNODE_TCP
    ok CPNODE_TCP
  '';

  # Client phases, sweep mode: one cp_node run per experiment.
  expSysctls = lib.unique (lib.concatMap (e: builtins.attrNames e.sysctls) experiments);
  setFor = e: lib.concatStringsSep " "
    (lib.mapAttrsToList (k: v: "net.homa.${k}=${toString v}") e.sysctls);
  runOne = e: ''
    both "sysctl -q -w $defaults ${setFor e}"
    c0=$(${stats} | snap)
    s0=$(on_peer ${stats} | snap)
    out=$(timeout ${toString pair.loadSeconds} cp_node client --protocol ${e.proto} \
      --workload ${e.workload} --gbps ${e.gbps} --first-server 0 --server-nodes 1 --id 1 \
      ${lib.optionalString (e.proto == "homa") "--first-port ${toString pair.cpNodeHomaPort}"} \
      2>&1 || true)
    c1=$(${stats} | snap)
    s1=$(on_peer ${stats} | snap)
    line=$(echo "$out" | grep ' clients: ' | tail -n 1 | sed -E 's/^.*clients: //')
    echo "HOMA_EXP name=${e.name} ''${line:-NO_STATS} | client: $(delta "$c0" "$c1")| server: $(delta "$s0" "$s1")"
  '';
  sweepPhases = ''
    # Run a command on the server through its control shell.
    on_peer() { echo "$1" | timeout 30 socat -t 20 - "TCP:$peer:${toString pair.ctlPort}"; }
    # Run on both nodes; fail unless the server confirms it ran the command.
    both() {
      eval "$1"
      on_peer "$1 && echo CTL_OK" | grep -q '^CTL_OK$' || fail CTL
    }
    ${metrics.snapDelta}
    # Each run starts from the defaults, then applies its own sysctls.
    defaults=""
    for k in ${lib.concatStringsSep " " expSysctls}; do
      defaults="$defaults net.homa.$k=$(sysctl -n "net.homa.$k")"
    done
    echo "HOMA_EXP_DEFAULTS$defaults"

    ${lib.concatMapStrings runOne experiments}
    both "sysctl -q -w $defaults"
    ok SWEEP
  '';
in
{
  inherit (metrics) nodeStats;

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

      ${pkgs.lib.optionalString isExp ''
        # Sweep mode: a shell on the private link so the client can set sysctls and read
        # metrics on this node.
        socat TCP-LISTEN:${toString pair.ctlPort},fork,reuseaddr SYSTEM:${pkgs.bash}/bin/bash &
      ''}
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

      ${if isExp then sweepPhases else normalPhases}
      rmmod homa || fail RMMOD
      ok RMMOD
      dmesg_gate || fail DMESG
      ok DMESG

      report PASS
      echo HOMA_PAIR_PASS
    '';
  };
}
