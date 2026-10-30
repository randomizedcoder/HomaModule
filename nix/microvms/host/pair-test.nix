# nix/microvms/host/pair-test.nix
#
# Orchestrator for the two-VM pair test (PLAN-pairs.md, uds-rdma-proxy pattern, console
# markers as in smoke-test.nix). Both guests drive themselves (pair.nix) and power off when done,
# so the host only has to:
#   1. start node0 (server), whose QEMU binds its end of the link (UDP for "dgram", a TCP
#      listen for "socket");
#   2. wait until that port is open (checked with ss; with "socket" a probe connection
#      would take the link's only accept);
#   3. start node1 (client);
#   4. wait for both qemu processes to exit, then grep both consoles:
#        node1: HOMA_PAIR_PASS            node0: HOMA_PAIR_SERVER_PASS
# Logs go to $HOMA_VM_LOGDIR (default: a fresh mktemp -d), printed at the start.

{ pkgs
, lib
, constants
, serverRunner      # declaredRunner for the pairNode = "server" guest
, clientRunner      # declaredRunner for the pairNode = "client" guest
, label ? ""        # "", "-6_12-7_3" (server kernel first), ...
, port              # host port of the QEMU socket link; unique per pair so pairs can run together
, link ? "dgram"    # "dgram" (node0 binds UDP) | "socket" (node0 listens on TCP)
}:

let
  pair = constants.pair;
  # How to see that node0's QEMU has its end of the link open.
  ssFlags = if link == "dgram" then "-Hlun" else "-Hltn";
in
pkgs.writeShellApplication {
  name = "homa-pair-test${label}";
  runtimeInputs = with pkgs; [ coreutils gnugrep iproute2 procps ];
  text = ''
    logdir="''${HOMA_VM_LOGDIR:-$(mktemp -d)}"
    mkdir -p "$logdir"
    slog="$logdir/node0${label}.log"
    clog="$logdir/node1${label}.log"
    port=${toString port}
    echo "console logs: $slog $clog"

    if ss ${ssFlags} "sport = :$port" | grep -q .; then
      echo "port $port is already in use (another pair test running?)"
      echo "VERDICT: FAIL"
      exit 1
    fi

    timeout --kill-after=10s ${toString pair.runTimeout}s \
      ${serverRunner}/bin/microvm-run > "$slog" 2>&1 &
    spid=$!

    for _ in $(seq 60); do
      ss ${ssFlags} "sport = :$port" | grep -q . && break
      kill -0 "$spid" 2>/dev/null || break
      sleep 0.5
    done
    if ! ss ${ssFlags} "sport = :$port" | grep -q .; then
      echo "node0 never listened on 127.0.0.1:$port"
      tail -n 30 "$slog"
      kill "$spid" 2>/dev/null || true
      echo "VERDICT: FAIL"
      exit 1
    fi

    cstatus=0
    timeout --kill-after=10s ${toString pair.runTimeout}s \
      ${clientRunner}/bin/microvm-run > "$clog" 2>&1 || cstatus=$?
    [ "$cstatus" = 124 ] && echo "node1 timed out"

    # The server powers off after the client's report; give it a moment, then stop it.
    for _ in $(seq 60); do
      kill -0 "$spid" 2>/dev/null || break
      sleep 1
    done
    kill "$spid" 2>/dev/null || true
    wait "$spid" 2>/dev/null || true

    # Lines look like "[  13.44] homa-pair-client[522]: HOMA_PAIR_ECHO_OK"; -a because the
    # logs also hold terminal escape sequences.
    show() { grep -aE '\]: HOMA_(PAIR_|EXP)' "$1" | sed -E 's/^.*\]: //' | tr -d '\r' || true; }
    echo "--- node0 (server)"
    show "$slog"
    echo "--- node1 (client)"
    show "$clog"

    verdict=PASS
    grep -aqE '\]: HOMA_PAIR_SERVER_PASS' "$slog" || verdict=FAIL
    grep -aqE '\]: HOMA_PAIR_PASS' "$clog" || verdict=FAIL
    if [ "$verdict" = FAIL ]; then
      for f in "$slog" "$clog"; do
        if ! grep -aqE '\]: HOMA_PAIR_(SERVER_)?(PASS|FAIL)' "$f"; then
          echo "--- $(basename "$f") never reported; last console lines:"
          tail -n 30 "$f"
        fi
      done
    fi
    echo "VERDICT: $verdict"
    [ "$verdict" = PASS ]
  '';
}
