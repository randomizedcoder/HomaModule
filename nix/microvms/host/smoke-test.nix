# nix/microvms/host/smoke-test.nix
#
# The microVM orchestrator (xtcp2 pattern). Produces a writeShellApplication that boots a
# guest built with autoTest=true, captures its serial console, and returns a verdict. The
# guest runs the smoke test itself (smoke.nix) and powers off, so the host only waits for
# qemu to exit and greps the console log:
#   HOMA_SMOKE_PASS          -> VERDICT: PASS
#   HOMA_SMOKE_FAIL:<phase>  -> VERDICT: FAIL (phase reported)
#   neither before timeout   -> VERDICT: FAIL (boot or hang)
#
# The log is kept in $HOMA_VM_LOGDIR (default: a fresh mktemp -d), printed at the start.

{ pkgs
, constants
, runner            # config.microvm.declaredRunner for an autoTest guest
, label ? ""        # "", "-debug", "-7_3", ...
, withSanitizers ? false
}:

let
  timeout = if withSanitizers then constants.bootTimeoutDebug else constants.bootTimeout;
in
pkgs.writeShellApplication {
  name = "homa-microvm-test${label}";
  runtimeInputs = [ pkgs.coreutils pkgs.gnugrep ];
  text = ''
    logdir="''${HOMA_VM_LOGDIR:-$(mktemp -d)}"
    mkdir -p "$logdir"
    log="$logdir/console${label}.log"
    echo "microVM console log: $log"

    status=0
    timeout --kill-after=10s ${toString timeout}s ${runner}/bin/microvm-run > "$log" 2>&1 || status=$?
    [ "$status" = 124 ] && echo "microVM timed out after ${toString timeout}s"

    # Console lines look like "[   13.44] homa-smoke[522]: HOMA_SMOKE_PASS"; -a because the
    # log also holds terminal escape sequences.
    marker='homa-smoke\[[0-9]+\]: HOMA_SMOKE_'
    grep -aE "$marker" "$log" | tr -d '\r' || true

    if grep -aqE "''${marker}PASS" "$log"; then
      echo "VERDICT: PASS"
      exit 0
    fi
    if ! grep -aqE "''${marker}FAIL" "$log"; then
      echo "smoke test never reported; last console lines:"
      tail -n 30 "$log"
    fi
    echo "VERDICT: FAIL"
    exit 1
  '';
}
