# nix/microvms/lifecycle-lib.nix
#
# Bash shared by the lifecycle tests (lifecycle.nix: one VM; pair-lifecycle.nix: two). It
# drives one or more guests built with consolePorts (mkVm.nix), each named by a key such as
# "vm" or "node0", through phases that each have a timeout and a time:
#
#   lc_start <n> <phase> <runner> <serial port> <virtio port>   qemu up, console ports open
#   lc_serial <n> <phase>        first kernel line in serial.log (ttyS0, logged from the start)
#   lc_virtio <n> <phase> <port> a root shell answering on hvc0 (the fast virtio console)
#   lc_dmesg <n> <phase>         no BUG/Oops/WARNING/KASAN/UBSAN in dmesg, read over hvc0
#   lc_shutdown <n> <phase>      poweroff over hvc0
#   lc_exit <n> <phase>          qemu exits, after the poweroff
#   lc_serial_log <n> <phase>    no oops anywhere in serial.log, including after the shell
#                                has gone (late RCU callbacks: STATUS.md F8)
#   lc_verdict                   the phase table (also summary.md) and the VERDICT line
#
# Before lc_start, set dir[<n>] (the guest's log directory, which is also its qemu's
# working directory) and sfx[<n>] (appended to its phase names, e.g. " node0"). Tests add
# their own phases with con_run, need_shell and record. A failed phase does not stop the
# run, but phases that need a guest's hvc0 shell are SKIPped once it is gone.

{ constants }:

let
  t = constants.lifecycle.timeouts;
in
rec {
  oops = "BUG:|Oops|WARNING:|KASAN|UBSAN|general protection fault|list_add corruption";

  text = ''
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

    declare -A dir=() sfx=() vm=() con=() shell=() sent_poweroff=()
    cleanup() {
      local n
      for n in "''${!vm[@]}"; do
        if [ -n "''${vm[$n]}" ]; then kill "''${vm[$n]}" 2>/dev/null || true; fi
      done
    }
    trap cleanup EXIT
    # A write to a console after qemu has gone must fail, not kill this script.
    trap "" PIPE

    vm_alive() { [ -n "''${vm[$1]:-}" ] && kill -0 "''${vm[$1]}" 2>/dev/null; }

    # con_run <n> <timeout> <log> <command>: run a command in guest n's hvc0 shell,
    # appending its output to <log>. Returns the command's exit code, or 124 on timeout.
    # Every command ends with a numbered marker; output from earlier, abandoned commands
    # is logged and skipped. The quotes inside the marker keep the shell's echo of it from
    # matching. Returns 125, and clears shell[n], once the console is closed.
    cmd_id=0
    con_run() {
      local n=$1 deadline=$((SECONDS + $2)) log=$3 line buf="" rc st
      cmd_id=$((cmd_id + 1))
      touch "$log"
      if ! printf "%s; echo \"HOMA_LC_\"\"END %d rc=\$?\"\n" "$4" "$cmd_id" 1>&"''${con[$n]}" 2>/dev/null; then
        shell[$n]=0
        return 125
      fi
      while [ "$SECONDS" -lt "$deadline" ]; do
        st=0
        IFS= read -r -t 1 -u "''${con[$n]}" line || st=$?
        if [ "$st" -gt 128 ]; then
          buf+=$line # timed out mid-line: keep the part read so far
          continue
        elif [ "$st" != 0 ]; then
          shell[$n]=0 # the console closed (qemu exited)
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
    # con_cap: con_run with <log> emptied first, so it holds just this command's output.
    con_cap() {
      : > "$3"
      con_run "$@"
    }

    # need_shell <n> <phase> <name>: record a SKIP and return 1 if guest n's shell is gone.
    need_shell() {
      [ "''${shell[$1]:-0}" = 1 ] && return 0
      record "$2" "$3" skip "$(now_ms)" "no shell on hvc0"
      return 1
    }

    lc_start() {
      local n=$1 start rc=1
      start=$(now_ms)
      mkdir -p "''${dir[$n]}"
      (cd "''${dir[$n]}" && exec "$3/bin/microvm-run") > "''${dir[$n]}/qemu.log" 2>&1 &
      vm[$n]=$!
      shell[$n]=0
      sent_poweroff[$n]=0
      for _ in $(seq $((${toString t.start} * 10))); do
        vm_alive "$n" || break
        if (: <> "/dev/tcp/127.0.0.1/$4") 2>/dev/null; then
          rc=0
          break
        fi
        sleep 0.1
      done
      record "$2" "start''${sfx[$n]}" "$rc" "$start" "qemu pid ''${vm[$n]}, consoles on $4/$5"
    }

    # NixOS boots "quiet", so the first line on ttyS0 is any kernel message, not the banner.
    lc_serial() {
      local n=$1 start rc=1 first=""
      start=$(now_ms)
      for _ in $(seq $((${toString t.serial} * 5))); do
        vm_alive "$n" || break
        first=$(grep -aom 1 '^\[ *[0-9]*\.[0-9]*\]' "''${dir[$n]}/serial.log" 2>/dev/null || true)
        if [ -n "$first" ]; then
          rc=0
          break
        fi
        sleep 0.2
      done
      record "$2" "serial''${sfx[$n]}" "$rc" "$start" "first kernel line at $first"
    }

    # Probe until the autologin shell answers; earlier probes are buffered and answered
    # late, which con_run's numbered markers skip.
    lc_virtio() {
      local n=$1 start rc=1 connected=0 fd up="" kver uptime
      start=$(now_ms)
      if exec {fd}<> "/dev/tcp/127.0.0.1/$3"; then
        connected=1
        con[$n]=$fd
      fi
      while [ "$connected" = 1 ] && vm_alive "$n" \
        && [ $(( ($(now_ms) - start) / 1000 )) -lt ${toString t.virtio} ]; do
        # A plain shell: no echo, no (coloured) prompt, no pager.
        if con_run "$n" 3 "''${dir[$n]}/virtio.log" "stty -echo; PS1=; PROMPT_COMMAND=; export TERM=dumb PAGER=cat SYSTEMD_PAGER="; then
          rc=0
          shell[$n]=1
          break
        fi
      done
      if [ "''${shell[$n]}" = 1 ]; then
        con_cap "$n" ${toString t.command} "''${dir[$n]}/uptime.log" "echo \$(uname -r) \$(cut -d' ' -f1 /proc/uptime)" || true
        read -r kver uptime < <(tail -n 1 "''${dir[$n]}/uptime.log") || true
        up="kernel $kver, guest uptime $uptime s"
      fi
      record "$2" "virtio''${sfx[$n]}" "$rc" "$start" "$up"
    }

    lc_dmesg() {
      local n=$1 start rc=0 log="''${dir[$1]}/dmesg.log"
      need_shell "$n" "$2" "dmesg''${sfx[$n]}" || return 0
      start=$(now_ms)
      con_cap "$n" ${toString t.command} "$log" "dmesg" || rc=$?
      if grep -aqE '${oops}' "$log"; then
        rc=1
        grep -aE '${oops}' "$log" | head -n 5 | sed 's/^/    /'
      fi
      record "$2" "dmesg''${sfx[$n]}" "$rc" "$start" "$(wc -l < "$log") lines"
    }

    lc_shutdown() {
      local n=$1 start rc=0
      need_shell "$n" "$2" "shutdown''${sfx[$n]}" || return 0
      start=$(now_ms)
      printf 'poweroff\n' 1>&"''${con[$n]}" 2>/dev/null || rc=$?
      sent_poweroff[$n]=1
      record "$2" "shutdown''${sfx[$n]}" "$rc" "$start" "poweroff sent over hvc0"
    }

    lc_exit() {
      local n=$1 start rc=1 detail="after poweroff"
      start=$(now_ms)
      for _ in $(seq $((${toString t.exit} * 5))); do
        if ! vm_alive "$n"; then
          rc=0
          break
        fi
        sleep 0.2
      done
      if [ "$rc" = 0 ]; then
        wait "''${vm[$n]}" 2>/dev/null || true
        vm[$n]=""
        if [ "''${sent_poweroff[$n]}" = 0 ]; then
          rc=1
          detail="qemu exited before poweroff (guest crash?)"
        fi
      else
        detail="still running after ${toString t.exit} s"
      fi
      record "$2" "exit''${sfx[$n]}" "$rc" "$start" "$detail"
    }

    lc_serial_log() {
      local n=$1 start rc=0 log="''${dir[$1]}/serial.log"
      start=$(now_ms)
      if grep -aqE '${oops}' "$log" 2>/dev/null; then
        rc=1
        grep -aE '${oops}|RIP:' "$log" | head -n 6 | sed 's/^/    /'
      fi
      record "$2" "serial-log''${sfx[$n]}" "$rc" "$start" "$(wc -l < "$log" 2>/dev/null || echo 0) lines"
    }

    lc_verdict() {
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
    }
  '';
}
