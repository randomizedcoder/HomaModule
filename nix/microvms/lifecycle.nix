# nix/microvms/lifecycle.nix
#
# Lifecycle test (pcp/xdp2 pattern): the host boots a guest with two consoles (mkVm.nix
# consolePorts) and drives it phase by phase, with a timeout and a time for each
# (lifecycle-lib.nix):
#
#   1  start      qemu running, console ports listening
#   2  serial     first kernel line in serial.log (ttyS0, 115200 baud, logged from the start)
#   2b virtio     a root shell answering on hvc0 (the fast virtio console)
#   3  smoke      homa-smoke (smoke.nix) over hvc0: insmod, echo, GRO/RPS, rmmod
#   4  cycles     insmod / netns add+del / rmmod, moduleCycles times (pernet init and exit)
#   5  dmesg      no BUG/Oops/WARNING/KASAN/UBSAN in the guest's dmesg, read over hvc0
#   6  shutdown   poweroff over hvc0
#   7  exit       qemu exits
#   8  serial-log no oops anywhere in serial.log, including after the shell has gone
#                 (late RCU callbacks: STATUS.md F8)
#
# The phase table is printed and written to summary.md; the last line is the VERDICT. Logs
# are in $HOMA_VM_LOGDIR (default: a fresh mktemp -d), which is also qemu's working
# directory.

{ pkgs
, lib
, constants
, runner          # config.microvm.declaredRunner for a guest built with consolePorts
, consolePorts    # { serial; virtio; }
, label ? ""
}:

let
  lc = constants.lifecycle;
  t = lc.timeouts;
  lclib = import ./lifecycle-lib.nix { inherit constants; };
in
pkgs.writeShellApplication {
  name = "homa-lifecycle${label}";
  runtimeInputs = with pkgs; [ coreutils gnugrep gnused ];
  text = ''
    logdir="''${HOMA_VM_LOGDIR:-$(mktemp -d)}"
    mkdir -p "$logdir"
    cd "$logdir"
    echo "lifecycle${label}: logs in $logdir"

    ${lclib.text}

    dir[vm]=.
    sfx[vm]=""
    lc_start vm 1 ${runner} ${toString consolePorts.serial} ${toString consolePorts.virtio}
    lc_serial vm 2
    lc_virtio vm 2b ${toString consolePorts.virtio}

    # ── 3 smoke ──────────────────────────────────────────────────────────────────────
    if need_shell vm 3 smoke; then
      start=$(now_ms)
      rc=0
      con_run vm ${toString t.smoke} smoke.log "homa-smoke 2>&1" || rc=$?
      grep -a 'HOMA_SMOKE_' smoke.log | sed 's/^/    /' || true
      detail=$(grep -aoE 'HOMA_SMOKE_(PASS|FAIL:[A-Z_]+)' smoke.log | tail -n 1 || true)
      if [ -z "$detail" ]; then
        detail="no verdict (rc $rc), last step: $(grep -aoE 'HOMA_SMOKE_[A-Z_]+_OK' smoke.log | tail -n 1 || true)"
      fi
      record 3 smoke "$rc" "$start" "$detail"
    fi

    # ── 4 cycles ─────────────────────────────────────────────────────────────────────
    if need_shell vm 4 cycles; then
      # In a subshell, so a failure ends the loop but not the console's shell.
      start=$(now_ms)
      rc=0
      con_run vm ${toString t.cycles} cycles.log \
        "(set -e; for i in \$(seq ${toString lc.moduleCycles}); do insmod \"\$HOMA_KO\"; ip netns add homa-lc; ip netns exec homa-lc ip link set lo up; ip netns del homa-lc; rmmod homa; echo cycle \$i ok; done) 2>&1" \
        || rc=$?
      record 4 cycles "$rc" "$start" "$(grep -c '^cycle .* ok' cycles.log || true) of ${toString lc.moduleCycles}"
    fi

    lc_dmesg vm 5
    lc_shutdown vm 6
    lc_exit vm 7
    lc_serial_log vm 8
    lc_verdict
  '';
}
