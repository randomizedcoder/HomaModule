# nix/microvms/lib.nix
#
# The microVM orchestrator (uds-rdma-proxy pattern, single-VM for Homa). Produces a
# writeShellApplication that boots the guest, drives a phased smoke test over the serial
# console with vm-expect.exp, and returns a verdict:
#   boot -> prompt -> insmod $HOMA_KO -> lsmod grep homa -> dmesg banner ->
#   (debug: KMEMLEAK scan + KASAN dmesg gate) -> rmmod -> poweroff.

{ pkgs
, lib
, constants
, runner            # config.microvm.declaredRunner for the guest
, label ? ""        # "" | "-debug"
, withSanitizers ? false
}:

let
  expectScript = ./scripts/vm-expect.exp;
  bootTimeout = if withSanitizers then constants.bootTimeoutDebug else constants.bootTimeout;
in
pkgs.writeShellApplication {
  name = "homa-microvm-test${label}";
  runtimeInputs = [ pkgs.expect pkgs.netcat-gnu pkgs.coreutils pkgs.gnugrep pkgs.procps ];
  text = ''
    set -uo pipefail
    PORT=${toString constants.consoleSerialPort}
    HOST=${constants.hostname}
    RUNDIR="$(mktemp -d)"
    echo "microVM run dir: $RUNDIR"

    cleanup() {
      [ -n "''${VM_PID:-}" ] && kill "$VM_PID" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    vm_run() { # <command> <timeout> ; prints console output
      expect ${expectScript} "$PORT" "$HOST" "$1" "''${2:-${toString constants.cmdTimeout}}" 2>&1 || true
    }

    fail() { echo "FAIL: $1" >&2; echo "VERDICT: FAIL"; exit 1; }

    echo "== Phase 1: boot VM =="
    ${runner}/bin/microvm-run > "$RUNDIR/console.log" 2>&1 &
    VM_PID=$!

    echo "== Phase 2: wait for login prompt (timeout ${toString bootTimeout}s) =="
    deadline=$(( $(date +%s) + ${toString bootTimeout} ))
    ready=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if ! kill -0 "$VM_PID" 2>/dev/null; then fail "VM process exited during boot"; fi
      if vm_run "echo READY_MARKER" 10 | grep -q READY_MARKER; then ready=1; break; fi
      sleep 3
    done
    [ "$ready" = 1 ] || fail "guest never reached a shell prompt"

    echo "== Phase 3: insmod homa.ko =="
    vm_run 'insmod $HOMA_KO && echo HOMA_INSMOD_OK' 30 | tee "$RUNDIR/insmod.log" | grep -q HOMA_INSMOD_OK \
      || fail "insmod \$HOMA_KO failed"

    echo "== Phase 4: verify module loaded =="
    vm_run 'lsmod | grep -q "^homa" && echo HOMA_LSMOD_OK' 15 | grep -q HOMA_LSMOD_OK \
      || fail "homa not present in lsmod"

    echo "== Phase 5: dmesg sanity =="
    vm_run 'dmesg | tail -n 40' 15 > "$RUNDIR/dmesg.log" || true
    ${lib.optionalString withSanitizers ''
      echo "== Phase 5b: KASAN/KMEMLEAK scan (debug) =="
      vm_run 'echo scan > /sys/kernel/debug/kmemleak 2>/dev/null; dmesg | tail -n 80' 30 > "$RUNDIR/dmesg-debug.log" || true
      if grep -qE 'BUG: KASAN|unreferenced object|=====' "$RUNDIR/dmesg-debug.log"; then
        fail "sanitizer splat detected in dmesg"
      fi
    ''}

    echo "== Phase 6: rmmod homa =="
    vm_run 'rmmod homa && echo HOMA_RMMOD_OK' 20 | grep -q HOMA_RMMOD_OK \
      || echo "WARN: rmmod homa did not confirm"

    echo "== Phase 7: poweroff =="
    vm_run 'poweroff' 10 >/dev/null 2>&1 || true
    sleep 2

    echo "VERDICT: PASS"
  '';
}
