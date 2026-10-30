# nix/microvms/lifecycle.nix
#
# Lifecycle test (pcp/xdp2 pattern): the host boots a guest with two consoles (mkVm.nix
# consolePorts) and drives it phase by phase, with a timeout and a time for each:
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
# A failed phase does not stop the run, but phases that need the hvc0 shell are SKIPped
# once it is gone (e.g. the guest crashed). The phase table is printed and written to
# summary.md; the last line is the VERDICT. Logs are
# in $HOMA_VM_LOGDIR (default: a fresh mktemp -d), which is also qemu's working directory.

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
  oops = "BUG:|Oops|WARNING:|KASAN|UBSAN|general protection fault|list_add corruption";
in
pkgs.writeShellApplication {
  name = "homa-lifecycle${label}";
  runtimeInputs = with pkgs; [ coreutils gnugrep gnused ];
  text = ''
    logdir="''${HOMA_VM_LOGDIR:-$(mktemp -d)}"
    mkdir -p "$logdir"
    cd "$logdir"
    echo "lifecycle${label}: logs in $logdir"

    now_ms() { date +%s%3N; }

    rows=()
    failed=0
    # record <phase> <name> <rc|skip> <start ms> [detail]
    record() {
      local verdict=PASS ms
      if [ "$3" = skip ]; then
        verdict=SKIP
      elif [ "$3" != 0 ]; then
        verdict=FAIL
        failed=$((failed + 1))
      fi
      ms=$(( $(now_ms) - $4 ))
      rows+=("| $1 | $2 | $verdict | $ms | ''${5:-} |")
      echo "  phase $1 $2: $verdict ($ms ms)''${5:+: $5}"
    }

    vm=""
    con=""
    cleanup() {
      if [ -n "$vm" ]; then kill "$vm" 2>/dev/null || true; fi
    }
    trap cleanup EXIT
    # A write to the console after qemu has gone must fail, not kill this script.
    trap "" PIPE

    vm_alive() { kill -0 "$vm" 2>/dev/null; }

    # con_run <timeout> <log> <command>: run a command in the hvc0 shell, appending its
    # output to <log>. Returns the command's exit code, or 124 on timeout. Every command
    # ends with a numbered marker; output from earlier, abandoned commands is logged and
    # skipped. The quotes inside the marker keep the shell's echo of it from matching.
    # Returns 125, and clears $shell, once the console is closed.
    cmd_id=0
    shell=0
    con_run() {
      local deadline=$((SECONDS + $1)) log=$2 line buf="" rc st
      cmd_id=$((cmd_id + 1))
      touch "$log"
      if ! printf "%s; echo \"HOMA_LC_\"\"END %d rc=\$?\"\n" "$3" "$cmd_id" 1>&"$con" 2>/dev/null; then
        shell=0
        return 125
      fi
      while [ "$SECONDS" -lt "$deadline" ]; do
        st=0
        IFS= read -r -t 1 -u "$con" line || st=$?
        if [ "$st" -gt 128 ]; then
          buf+=$line # timed out mid-line: keep the part read so far
          continue
        elif [ "$st" != 0 ]; then
          shell=0 # the console closed (qemu exited)
          return 125
        fi
        line=$buf$line
        buf=""
        line=''${line%$'\r'}
        case "$line" in
          *"HOMA_LC_END $cmd_id rc="*)
            rc=''${line##*rc=}
            return "''${rc%%[!0-9]*}"
            ;;
        esac
        printf '%s\n' "$line" >> "$log"
      done
      return 124
    }

    # ── 1 start ──────────────────────────────────────────────────────────────────────
    start=$(now_ms)
    ${runner}/bin/microvm-run > qemu.log 2>&1 &
    vm=$!
    rc=1
    for _ in $(seq $((${toString t.start} * 10))); do
      vm_alive || break
      if (: <> /dev/tcp/127.0.0.1/${toString consolePorts.serial}) 2>/dev/null; then
        rc=0
        break
      fi
      sleep 0.1
    done
    record 1 start "$rc" "$start" "qemu pid $vm, consoles on ${toString consolePorts.serial}/${toString consolePorts.virtio}"

    # ── 2 serial ─────────────────────────────────────────────────────────────────────
    start=$(now_ms)
    # NixOS boots "quiet", so the first line on ttyS0 is any kernel message, not the banner.
    rc=1
    first=""
    for _ in $(seq $((${toString t.serial} * 5))); do
      vm_alive || break
      first=$(grep -aom 1 '^\[ *[0-9]*\.[0-9]*\]' serial.log 2>/dev/null || true)
      if [ -n "$first" ]; then
        rc=0
        break
      fi
      sleep 0.2
    done
    record 2 serial "$rc" "$start" "first kernel line at $first"

    # ── 2b virtio ────────────────────────────────────────────────────────────────────
    # Probe until the autologin shell answers; earlier probes are buffered and answered
    # late, which con_run's numbered markers skip.
    start=$(now_ms)
    rc=1
    connected=0
    if exec {con}<> /dev/tcp/127.0.0.1/${toString consolePorts.virtio}; then connected=1; fi
    while [ "$connected" = 1 ] && vm_alive \
      && [ $(( ($(now_ms) - start) / 1000 )) -lt ${toString t.virtio} ]; do
      # A plain shell: no echo, no (coloured) prompt, no pager.
      if con_run 3 virtio.log "stty -echo; PS1=; PROMPT_COMMAND=; export TERM=dumb PAGER=cat SYSTEMD_PAGER="; then
        rc=0
        shell=1
        break
      fi
    done
    up=""
    if [ "$shell" = 1 ]; then
      con_run ${toString t.command} uptime.log "echo \$(uname -r) \$(cut -d' ' -f1 /proc/uptime)" || true
      read -r kver uptime < <(tail -n 1 uptime.log)
      up="kernel $kver, guest uptime $uptime s"
    fi
    record 2b virtio "$rc" "$start" "$up"

    # need_shell <phase> <name>: record a SKIP and return 1 if the hvc0 shell is gone.
    need_shell() {
      [ "$shell" = 1 ] && return 0
      record "$1" "$2" skip "$(now_ms)" "no shell on hvc0"
      return 1
    }

    sent_poweroff=0

    # ── 3 smoke ──────────────────────────────────────────────────────────────────────
    if need_shell 3 smoke; then
      start=$(now_ms)
      rc=0
      con_run ${toString t.smoke} smoke.log "homa-smoke 2>&1" || rc=$?
      grep -a 'HOMA_SMOKE_' smoke.log | sed 's/^/    /' || true
      detail=$(grep -aoE 'HOMA_SMOKE_(PASS|FAIL:[A-Z_]+)' smoke.log | tail -n 1 || true)
      if [ -z "$detail" ]; then
        detail="no verdict (rc $rc), last step: $(grep -aoE 'HOMA_SMOKE_[A-Z_]+_OK' smoke.log | tail -n 1 || true)"
      fi
      record 3 smoke "$rc" "$start" "$detail"
    fi

    # ── 4 cycles ─────────────────────────────────────────────────────────────────────
    if need_shell 4 cycles; then
      # In a subshell, so a failure ends the loop but not the console's shell.
      start=$(now_ms)
      rc=0
      con_run ${toString t.cycles} cycles.log \
        "(set -e; for i in \$(seq ${toString lc.moduleCycles}); do insmod \"\$HOMA_KO\"; ip netns add homa-lc; ip netns exec homa-lc ip link set lo up; ip netns del homa-lc; rmmod homa; echo cycle \$i ok; done) 2>&1" \
        || rc=$?
      record 4 cycles "$rc" "$start" "$(grep -c '^cycle .* ok' cycles.log || true) of ${toString lc.moduleCycles}"
    fi

    # ── 5 dmesg ──────────────────────────────────────────────────────────────────────
    if need_shell 5 dmesg; then
      start=$(now_ms)
      rc=0
      con_run ${toString t.command} dmesg.log "dmesg" || rc=$?
      if grep -aqE '${oops}' dmesg.log; then
        rc=1
        grep -aE '${oops}' dmesg.log | head -n 5 | sed 's/^/    /'
      fi
      record 5 dmesg "$rc" "$start" "$(wc -l < dmesg.log) lines"
    fi

    # ── 6 shutdown ───────────────────────────────────────────────────────────────────
    if need_shell 6 shutdown; then
      start=$(now_ms)
      rc=0
      printf 'poweroff\n' 1>&"$con" 2>/dev/null || rc=$?
      sent_poweroff=1
      record 6 shutdown "$rc" "$start" "poweroff sent over hvc0"
    fi

    # ── 7 exit ───────────────────────────────────────────────────────────────────────
    start=$(now_ms)
    rc=1
    for _ in $(seq $((${toString t.exit} * 5))); do
      if ! vm_alive; then
        rc=0
        break
      fi
      sleep 0.2
    done
    detail="after poweroff"
    if [ "$rc" = 0 ]; then
      wait "$vm" 2>/dev/null || true
      vm=""
      if [ "$sent_poweroff" = 0 ]; then
        rc=1
        detail="qemu exited before poweroff (guest crash?)"
      fi
    else
      detail="still running after ${toString t.exit} s"
    fi
    record 7 exit "$rc" "$start" "$detail"

    # ── 8 serial-log ─────────────────────────────────────────────────────────────────
    start=$(now_ms)
    rc=0
    if grep -aqE '${oops}' serial.log 2>/dev/null; then
      rc=1
      grep -aE '${oops}|RIP:' serial.log | head -n 6 | sed 's/^/    /'
    fi
    record 8 serial-log "$rc" "$start" "$(wc -l < serial.log 2>/dev/null || echo 0) lines"

    {
      echo "| Phase | Name | Result | Time (ms) | Detail |"
      echo "|---|---|---|---|---|"
      printf '%s\n' "''${rows[@]}"
    } > summary.md
    echo
    cat summary.md
    echo
    if [ "$failed" -gt 0 ]; then
      echo "VERDICT: FAIL ($failed phases)"
      exit 1
    fi
    echo "VERDICT: PASS"
  '';
}
