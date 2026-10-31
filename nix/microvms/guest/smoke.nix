# nix/microvms/guest/smoke.nix
#
# The in-guest smoke test (xtcp2 pattern): a shellcheck-clean script that the guest runs as a
# systemd oneshot with its output on the serial console. Each phase prints HOMA_SMOKE_<phase>_OK,
# and the run ends with exactly one of HOMA_SMOKE_PASS or HOMA_SMOKE_FAIL:<phase>; the host
# (smoke-test.nix) greps the captured console log for them.
#
#   insmod -> lsmod -> loopback echo RPCs (demo_server1 <- demo_client1, 100 B .. 1 MB:
#   exercises sendmsg and the recvmsg path) -> the same echo across two netns over veth with
#   GRO and the RPS flow table on (exercises homa_gro_complete -> homa_set_softirq_cpu) ->
#   (sanitizers: kmemleak scan + KASAN gate) -> rmmod

{ pkgs
, oopsRegex # constants.oopsRegex
, echoRpcs # constants.echoRpcs
, homaKoPath
, homaUtils
, withSanitizers ? false
}:

pkgs.writeShellApplication {
  name = "homa-smoke";
  runtimeInputs = with pkgs; [ kmod coreutils gnugrep gawk util-linux iproute2 ethtool homaUtils ];
  text = ''
    fail() {
      echo "HOMA_SMOKE_FAIL:$1"
      dmesg | tail -n 40
      exit 1
    }
    ok() { echo "HOMA_SMOKE_$1_OK"; }

    echo "HOMA_SMOKE_START kernel=$(uname -r)"

    insmod ${homaKoPath} || fail INSMOD
    ok INSMOD

    grep -q '^homa ' /proc/modules || fail LSMOD
    ok LSMOD

    demo_server1 > /tmp/demo_server1.log 2>&1 &
    server=$!
    sleep 1
    responses=$(timeout 30 demo_client1 127.0.0.1 4000 | grep -c '^Received response' || true)
    kill "$server" 2>/dev/null || true
    wait "$server" 2>/dev/null || true
    echo "HOMA_SMOKE_ECHO responses=$responses (want ${toString echoRpcs})"
    [ "$responses" = ${toString echoRpcs} ] || fail ECHO
    ok ECHO

    # GRO + RPS: loopback skips GRO, so repeat the echo between two network namespaces over
    # a veth pair with GRO on (veth then receives through NAPI). veth only hands a packet to
    # GRO if the sending device has TSO off (veth_skb_is_eligible_for_gro), so turn it off.
    # With the RPS socket flow table allocated, homa_gro_complete -> homa_set_softirq_cpu
    # writes table entries; on 7.1+ that is the rps_tag_ptr code. A kprobe counts the calls
    # to prove it ran.
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries || fail GRO_SYSCTL
    ip netns add homa-srv
    ip netns add homa-cli
    ip link add homa-v0 netns homa-srv type veth peer name homa-v1 netns homa-cli
    ip -n homa-srv addr add 10.77.0.1/24 dev homa-v0
    ip -n homa-cli addr add 10.77.0.2/24 dev homa-v1
    for ns_dev in homa-srv:homa-v0 homa-cli:homa-v1; do
      ns=''${ns_dev%%:*}
      dev=''${ns_dev#*:}
      ip -n "$ns" link set lo up
      ip -n "$ns" link set "$dev" up
      ip netns exec "$ns" ethtool -K "$dev" gro on tso off
    done

    tracing=/sys/kernel/tracing
    [ -e "$tracing/kprobe_events" ] || mount -t tracefs nodev "$tracing"
    for probe in homa_gro_receive homa_set_softirq_cpu; do
      echo "p:p_$probe $probe" >> "$tracing/kprobe_events" || fail GRO_KPROBE
      echo 1 > "$tracing/events/kprobes/p_$probe/enable"
    done

    ip netns exec homa-srv demo_server1 > /tmp/demo_server1_gro.log 2>&1 &
    server=$!
    sleep 1
    responses=$(timeout 30 ip netns exec homa-cli demo_client1 10.77.0.1 4000 \
      | grep -c '^Received response' || true)
    kill "$server" 2>/dev/null || true
    wait "$server" 2>/dev/null || true

    gro_hits=$(awk '$1 == "p_homa_gro_receive" { print $2 }' "$tracing/kprobe_profile")
    hits=$(awk '$1 == "p_homa_set_softirq_cpu" { print $2 }' "$tracing/kprobe_profile")
    for probe in homa_gro_receive homa_set_softirq_cpu; do
      echo 0 > "$tracing/events/kprobes/p_$probe/enable"
      echo "-:p_$probe" >> "$tracing/kprobe_events"
    done
    ip netns del homa-srv
    ip netns del homa-cli

    echo "HOMA_SMOKE_GRO responses=$responses (want ${toString echoRpcs}) homa_gro_receive calls=$gro_hits" \
      "homa_set_softirq_cpu calls=$hits"
    [ "$responses" = ${toString echoRpcs} ] || fail GRO
    [ "''${gro_hits:-0}" -gt 0 ] || fail GRO_NOT_USED
    [ "''${hits:-0}" -gt 0 ] || fail GRO_RPS
    ok GRO

    ${pkgs.lib.optionalString withSanitizers ''
      echo scan > /sys/kernel/debug/kmemleak 2>/dev/null || true
      sleep 5
      if dmesg | grep -qE 'BUG: KASAN|UBSAN:|unreferenced object'; then
        fail SANITIZER
      fi
      ok SANITIZER
    ''}

    rmmod homa || fail RMMOD
    ok RMMOD

    if dmesg | grep -qE '${oopsRegex}'; then
      fail DMESG
    fi
    ok DMESG

    echo HOMA_SMOKE_PASS
  '';
}
