# nix/microvms/pair-lifecycle.nix
#
# Pair lifecycle test (PLAN-pairs.md phase 4): the two-VM pair (node0 server, node1 client,
# on a private eth1 link) driven from the host over each guest's hvc0, with every phase
# timed (lifecycle-lib.nix). Neither guest runs a test of its own.
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

{ pkgs
, lib
, constants
, serverRunner    # declaredRunner: pairNode = "server", consolePorts = ports.node0
, clientRunner    # declaredRunner: pairNode = "client", consolePorts = ports.node1
, ports           # { node0 = { serial; virtio; }; node1 = { serial; virtio; }; }
, label ? ""
}:

let
  lc = constants.lifecycle;
  t = lc.timeouts;
  pair = constants.pair;
  netem = lc.netem;
  lclib = import ./lifecycle-lib.nix { inherit constants; };
  metrics = import ./metrics.nix { inherit pkgs lib; };
  peer = pair.nodes.server.ip;
  netemArgs = p: lib.optionalString (p.delay != null) "delay ${p.delay} "
    + "loss ${p.loss}% limit ${toString netem.limit}";
  # Output goes to a file (here and for echo), grepped afterwards: under the console shell's
  # job control, timeout's SIGTERM also reaches the rest of a pipeline ("Terminated"),
  # losing its output.
  cpNode = proto: "timeout ${toString pair.loadSeconds} cp_node client --protocol ${proto}"
    + " --workload ${pair.workload} --gbps ${pair.gbps} --first-server 0 --server-nodes 1 --id 1"
    + lib.optionalString (proto == "homa") " --first-port ${toString pair.cpNodeHomaPort}"
    + " > /tmp/cp_node_${proto}.out 2>&1 < /dev/null; grep ' clients: ' /tmp/cp_node_${proto}.out | tail -n 1";
in
# Shallower queues would let netem tail-drop under load and count it as link loss.
assert netem.limit >= 100000;
pkgs.writeShellApplication {
  name = "homa-pair-lifecycle${label}";
  runtimeInputs = with pkgs; [ coreutils gnugrep gnused gawk ];
  text = ''
    logdir="''${HOMA_VM_LOGDIR:-$(mktemp -d)}"
    mkdir -p "$logdir"
    cd "$logdir"
    echo "pair lifecycle${label}: logs in $logdir"

    ${lclib.text}
    ${metrics.snapDelta}

    peer=${peer}
    dir[node0]=node0
    sfx[node0]=" node0"
    dir[node1]=node1
    sfx[node1]=" node1"

    # both_shells <phase> <name>: record a SKIP and return 1 unless both shells answer.
    both_shells() {
      [ "''${shell[node0]:-0}" = 1 ] && [ "''${shell[node1]:-0}" = 1 ] && return 0
      record "$1" "$2" skip "$(now_ms)" "no shell on hvc0 (node0 ''${shell[node0]:-0}, node1 ''${shell[node1]:-0})"
      return 1
    }
    # get <deltas> <counter>: one counter from a delta line, 0 if absent.
    get() {
      echo "$1" | awk -v k="$2" '
        { for (i = 1; i <= NF; i++) { split($i, p, "="); if (p[1] == k) v = p[2] } }
        END { print v + 0 }'
    }
    # field <cp_node stats line> <word>: the word after <word> ("clients:", "P50", "P99").
    field() {
      echo "$1" | awk -v w="$2" '
        { for (i = 1; i < NF; i++) if ($i == w) { v = $(i + 1); exit } }
        END { print (v == "" ? "-" : v) }'
    }

    lc_start node0 1 ${serverRunner} ${toString ports.node0.serial} ${toString ports.node0.virtio}
    lc_start node1 1 ${clientRunner} ${toString ports.node1.serial} ${toString ports.node1.virtio}
    lc_serial node0 2
    lc_serial node1 2
    lc_virtio node0 3 ${toString ports.node0.virtio}
    lc_virtio node1 3 ${toString ports.node1.virtio}

    # ── 4 insmod ─────────────────────────────────────────────────────────────────────
    for n in node0 node1; do
      if need_shell "$n" 4 "insmod''${sfx[$n]}"; then
        start=$(now_ms)
        rc=0
        con_cap "$n" ${toString t.command} "''${dir[$n]}/insmod.log" "insmod \"\$HOMA_KO\" 2>&1" || rc=$?
        record 4 "insmod''${sfx[$n]}" "$rc" "$start" "$(head -n 1 "''${dir[$n]}/insmod.log")"
      fi
    done

    # ── 5 link ───────────────────────────────────────────────────────────────────────
    if need_shell node1 5 link; then
      start=$(now_ms)
      rc=0
      con_cap node1 ${toString t.command} node1/ping.log \
        "for i in \$(seq 20); do ping -c 1 -W 1 $peer > /dev/null && break; done; ping -q -c 3 -W 2 $peer" \
        || rc=$?
      record 5 link "$rc" "$start" "$(grep -aE 'packet loss|rtt' node1/ping.log | tr '\n' ' ')"
    fi

    # ── 6 servers ────────────────────────────────────────────────────────────────────
    # Each in a subshell, so the console's shell has no jobs to report.
    if need_shell node0 6 servers; then
      start=$(now_ms)
      rc=0
      con_cap node0 ${toString t.command} node0/servers.log \
        "(demo_server1 > /tmp/demo_server1.log 2>&1 < /dev/null &); (cp_node server --protocol homa --first-port ${toString pair.cpNodeHomaPort} > /tmp/cp_node_homa.log 2>&1 < /dev/null &); (cp_node server --protocol tcp > /tmp/cp_node_tcp.log 2>&1 < /dev/null &); sleep 1; echo demo_server1=\$(pgrep -cx demo_server1) cp_node=\$(pgrep -cx cp_node)" \
        || rc=$?
      detail=$(tail -n 1 node0/servers.log)
      [ "$detail" = "demo_server1=1 cp_node=2" ] || rc=1
      record 6 servers "$rc" "$start" "$detail"
    fi

    # traffic <phase> <name> <loss %, or "" without netem> [<counter>]: echo, then cp_node
    # Homa and TCP, from node1 to node0, with counter deltas on both nodes. With netem, also
    # checks each node's measured drop rate against the configured loss. <counter>, if
    # given, must have moved (summed over both nodes): packets_sent_RESEND under loss, the
    # qdisc and pacer counters with the Homa qdisc.
    traffic() {
      local phase=$1 name=$2 loss=$3 must=''${4:-} d=traffic/$2 start rc=0 why="" n echo_ homa \
        tcp dc ds pkts drops m drop_ok drop_detail="" resend moved=""
      both_shells "$phase" "traffic $name" || return 0
      start=$(now_ms)
      mkdir -p "$d"
      for n in node0 node1; do
        con_cap "$n" ${toString t.command} "$d/$n-stats0" homa-node-stats || rc=$?
      done
      con_cap node1 ${toString t.echo} "$d/echo.log" \
        "timeout ${toString (t.echo - 10)} demo_client1 $peer 4000 > /tmp/echo.out 2>&1 < /dev/null; grep -c '^Received response' /tmp/echo.out" || true
      echo_=$(tail -n 1 "$d/echo.log")
      con_cap node1 ${toString t.command} "$d/homa.log" "${cpNode "homa"}" || true
      homa=$(tail -n 1 "$d/homa.log")
      con_cap node1 ${toString t.command} "$d/tcp.log" "${cpNode "tcp"}" || true
      tcp=$(tail -n 1 "$d/tcp.log")
      for n in node0 node1; do
        con_cap "$n" ${toString t.command} "$d/$n-stats1" homa-node-stats || rc=$?
      done
      ds=$(delta "$(snap < "$d/node0-stats0")" "$(snap < "$d/node0-stats1")")
      dc=$(delta "$(snap < "$d/node1-stats0")" "$(snap < "$d/node1-stats1")")
      printf 'node0: %s\nnode1: %s\n' "$ds" "$dc" > "$d/deltas"

      [ "$echo_" = 6 ] || why+=" echo"
      # cp_node made progress if it timed any RPC (a P99): at 5 % loss TCP manages a few
      # RPCs a second, which its Kops field rounds to 0.00.
      awk -v k="$(field "$homa" P99)" 'BEGIN { exit !(k > 0) }' || why+=" homa"
      awk -v k="$(field "$tcp" P99)" 'BEGIN { exit !(k > 0) }' || why+=" tcp"
      if [ -n "$loss" ]; then
        for n in node0 node1; do
          con_cap "$n" ${toString t.command} "$d/$n-tc" "tc -s qdisc show dev eth1" || rc=$?
          read -r pkts drops < <(awk '
            /^qdisc netem/ { f = 1; next }
            f && $1 == "Sent" { sub(",", "", $7); print $4, $7; exit }' "$d/$n-tc") || true
          # Loss 0 must drop nothing. Otherwise allow up to twice the loss plus 0.5
          # points, and with 10k+ packets at least half of it (so netem is really on).
          read -r m drop_ok < <(awk -v p="''${pkts:-0}" -v d="''${drops:-0}" -v l="$loss" 'BEGIN {
            m = (p + d) ? 100 * d / (p + d) : 0
            ok = (l == 0) ? d == 0 : (m <= 2 * l + 0.5 && (p + d < 10000 || m >= l / 2))
            printf "%.2f %d\n", m, ok }')
          drop_detail+=" $n ''${drops:-?}/$(( ''${pkts:-0} + ''${drops:-0} )) ($m%)"
          [ "$drop_ok" = 1 ] || why+=" drops-$n"
        done
        drop_detail="; netem drops$drop_detail"
      fi
      resend=$(( $(get "$ds" packets_sent_RESEND) + $(get "$dc" packets_sent_RESEND) ))
      if [ -n "$must" ]; then
        moved=$(( $(get "$ds" "$must") + $(get "$dc" "$must") ))
        [ "$moved" -gt 0 ] || why+=" no-$must"
        moved="; $must $moved"
      fi
      [ -z "$why" ] || rc=1

      if [ "$name" = baseline ]; then
        # The lines homa-vm-matrix puts in its table.
        echo "HOMA_PAIR_ECHO responses=$echo_ (want 6)"
        echo "HOMA_PAIR_CPNODE_homa $homa"
        echo "HOMA_PAIR_CPNODE_tcp $tcp"
      fi
      sed 's/^/    /' "$d/deltas"
      record "$phase" "traffic $name" "$rc" "$start" \
        "echo $echo_/6; Homa $(field "$homa" clients:) Kops P50 $(field "$homa" P50) P99 $(field "$homa" P99) us; TCP $(field "$tcp" clients:) Kops P99 $(field "$tcp" P99) us$drop_detail; RESENDs $resend, resent $(( $(get "$ds" resent_packets) + $(get "$dc" resent_packets) )), rpc_timeouts $(( $(get "$ds" rpc_timeouts) + $(get "$dc" rpc_timeouts) )), tcp_retrans $(( $(get "$ds" tcp_retrans) + $(get "$dc" tcp_retrans) ))$moved''${why:+; failed:$why}"
    }

    # netem_set <phase> <name> <tc netem arguments>: replace eth1's root qdisc on both nodes,
    # so its counters start from zero, and check that the limit took.
    netem_set() {
      local phase=$1 name=$2 n start rc=0
      both_shells "$phase" "netem $name" || return 0
      start=$(now_ms)
      for n in node0 node1; do
        con_cap "$n" ${toString t.command} "''${dir[$n]}/netem-$name.log" \
          "tc qdisc del dev eth1 root 2> /dev/null; tc qdisc add dev eth1 root netem $3 && tc qdisc show dev eth1" \
          || rc=$?
        grep -aqE "^qdisc netem .*limit ${toString netem.limit}( |$)" "''${dir[$n]}/netem-$name.log" || rc=1
      done
      record "$phase" "netem $name" "$rc" "$start" "$(grep -a '^qdisc netem' node1/netem-"$name".log | sed 's/^qdisc netem [0-9a-f]*: root refcnt [0-9]* //')"
    }

    # ── 7 baseline, 8.i netem, 9 recovered ──────────────────────────────────────────
    traffic 7 baseline ""
    ${lib.concatImapStrings (i: p: ''
      netem_set 8.${toString i} ${p.name} ${lib.escapeShellArg (netemArgs p)}
      traffic 8.${toString i} ${p.name} ${p.loss} ${lib.optionalString (p.loss != "0") "packets_sent_RESEND"}
    '') netem.phases}
    if both_shells 9 "netem clear"; then
      start=$(now_ms)
      rc=0
      for n in node0 node1; do
        con_run "$n" ${toString t.command} "''${dir[$n]}/netem-clear.log" \
          "tc qdisc del dev eth1 root && ! tc qdisc show dev eth1 | grep -q netem" || rc=$?
      done
      record 9 "netem clear" "$rc" "$start" "default qdisc on eth1"
    fi
    traffic 9 recovered ""

    # ── 10 Homa qdisc, 11 paced, 12 off ──────────────────────────────────────────────
    # on_both <phase> <name> <log> <command>: run a command on both nodes; the detail is
    # node1's output.
    on_both() {
      local n start rc=0
      both_shells "$1" "$2" || return 0
      start=$(now_ms)
      for n in node0 node1; do
        con_cap "$n" ${toString t.command} "''${dir[$n]}/$3" "$4" || rc=$?
      done
      record "$1" "$2" "$rc" "$start" "$(tr '\n' ' ' < node1/"$3" | sed 's/  */ /g')"
    }
    # The pacer works from the link speed. virtio-net reports none (SPEED_UNKNOWN: round-4
    # candidate 5). Phase 11 sets net.homa.link_mbps, which the qdisc uses when the NIC
    # reports no speed, low enough that the pacer has to defer packets.
    on_both 10 "qdisc homa" qdisc-on.log \
      "sysctl -n net.homa.link_mbps > /tmp/link_mbps; homa-qdisc on > /tmp/qdisc.out && head -n 1 /tmp/qdisc.out && grep '^qdisc homa' /tmp/qdisc.out"
    traffic 10 homa-qdisc "" qdisc_tcp_packets
    on_both 11 "qdisc paced" qdisc-paced.log "sysctl -w net.homa.link_mbps=${toString lc.qdisc.pacedMbps}"
    traffic 11 homa-qdisc-paced "" pacer_homa_packets
    on_both 12 "qdisc off" qdisc-off.log \
      "sysctl -w net.homa.link_mbps=\$(cat /tmp/link_mbps) && homa-qdisc off && ! tc qdisc show dev eth1 | grep -q '^qdisc homa'"

    # ── 13 stop servers ──────────────────────────────────────────────────────────────
    if need_shell node0 13 "stop servers"; then
      start=$(now_ms)
      rc=0
      con_run node0 ${toString t.command} node0/servers.log \
        "pkill -x demo_server1; pkill -x cp_node; sleep 1; ! pgrep -x 'demo_server1|cp_node'" || rc=$?
      record 13 "stop servers" "$rc" "$start" ""
    fi

    # ── 14 rmmod ─────────────────────────────────────────────────────────────────────
    for n in node0 node1; do
      if need_shell "$n" 14 "rmmod''${sfx[$n]}"; then
        start=$(now_ms)
        rc=0
        con_cap "$n" ${toString t.command} "''${dir[$n]}/rmmod.log" "rmmod homa 2>&1" || rc=$?
        record 14 "rmmod''${sfx[$n]}" "$rc" "$start" "$(head -n 1 "''${dir[$n]}/rmmod.log")"
      fi
    done

    lc_dmesg node0 15
    lc_dmesg node1 15
    lc_shutdown node0 16
    lc_shutdown node1 16
    lc_exit node0 17
    lc_exit node1 17
    lc_serial_log node0 18
    lc_serial_log node1 18
    lc_verdict
  '';
}
