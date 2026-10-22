# nix/microvms/smoke.nix
#
# The in-guest smoke test (xtcp2 pattern): a shellcheck-clean script that the guest runs as a
# systemd oneshot with its output on the serial console. Each phase prints HOMA_SMOKE_<phase>_OK,
# and the run ends with exactly one of HOMA_SMOKE_PASS or HOMA_SMOKE_FAIL:<phase>; the host
# (lib.nix) greps the captured console log for them.
#
#   insmod -> lsmod -> loopback echo RPCs (demo_server1 <- demo_client1, 100 B .. 1 MB:
#   exercises sendmsg and the recvmsg path) -> (sanitizers: kmemleak scan + KASAN gate) ->
#   rmmod

{ pkgs
, homaKoPath
, homaUtils
, withSanitizers ? false
}:

pkgs.writeShellApplication {
  name = "homa-smoke";
  runtimeInputs = [ pkgs.kmod pkgs.coreutils pkgs.gnugrep pkgs.util-linux homaUtils ];
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
    echo "HOMA_SMOKE_ECHO responses=$responses (want 6)"
    [ "$responses" = 6 ] || fail ECHO
    ok ECHO

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

    if dmesg | grep -qE 'BUG:|Oops|WARNING:.*homa'; then
      fail DMESG
    fi
    ok DMESG

    echo HOMA_SMOKE_PASS
  '';
}
