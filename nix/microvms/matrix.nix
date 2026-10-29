# nix/microvms/matrix.nix
#
# One command for every VM test (PLAN-pairs.md phase 3): runs each per-kernel single-VM
# smoke test and each (server, client) pair test in parallel, then prints a summary table
# (also written to $logdir/summary.md):
#
#   | Test | Kernel(s) | Verdict | Time (s) | Echo | GRO calls | Homa Kops/s | Homa P50 / P99 (us) | TCP ... |
#
# Each test keeps its own console logs and output under $HOMA_VM_LOGDIR/<test>/. The tests
# share nothing on the host (each pair has its own link port), so they can all run at once;
# HOMA_VM_JOBS caps how many run together (default: all). Exits non-zero if any test fails.

{ pkgs
, lib
, tests   # list of { name, kernels, exe }: exe is a homa-microvm-test-* or homa-pair-test-* package
}:

pkgs.writeShellApplication {
  name = "homa-vm-matrix";
  runtimeInputs = with pkgs; [ coreutils gnugrep gawk ];
  text = ''
    logdir="''${HOMA_VM_LOGDIR:-$(mktemp -d)}"
    mkdir -p "$logdir"
    jobs="''${HOMA_VM_JOBS:-${toString (builtins.length tests)}}"
    echo "VM matrix: ${toString (builtins.length tests)} tests, up to $jobs at once; logs in $logdir"

    # run <name> <exe>: one test, its output in <name>.out, exit code and seconds in <name>.rc
    run() {
      local start rc=0
      start=$(date +%s)
      mkdir -p "$logdir/$1"
      # Each test runs in its own directory: microvm.nix puts the QMP socket
      # (<hostname>.sock) in the current directory, and every pair's server is node0.
      (cd "$logdir/$1" && HOMA_VM_LOGDIR="$logdir/$1" "$2") > "$logdir/$1.out" 2>&1 || rc=$?
      echo "$rc $(( $(date +%s) - start ))" > "$logdir/$1.rc"
      echo "  done: $1 (exit $rc)"
    }

    start=$(date +%s)
    ${lib.concatMapStrings (t: ''
      while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n || true; done
      run ${t.name} ${lib.getExe t.exe} &
    '') tests}
    wait

    # field <line> <word>: the word after <word> in a cp_node stats line ("clients:", "P50",
    # "P99"), or a dash when there is none (single-VM tests have no cp_node runs).
    field() {
      echo "$1" | awk -v w="$2" '
        { for (i = 1; i < NF; i++) if ($i == w) { v = $(i + 1); exit } }
        END { print (v == "" ? "—" : v) }'
    }

    summary="$logdir/summary.md"
    {
      echo "| Test | Kernel(s) | Verdict | Time (s) | Echo | GRO calls | Homa Kops/s | Homa P50 / P99 (us) | TCP Kops/s | TCP P50 / P99 (us) |"
      echo "|---|---|---|---|---|---|---|---|---|---|"
    } > "$summary"
    failed=0
    row() {
      local name=$1 kernels=$2 out="$logdir/$1.out" rc secs verdict echo_ gro homa tcp
      read -r rc secs < "$logdir/$name.rc"
      verdict=FAIL
      grep -q '^VERDICT: PASS' "$out" && verdict=PASS
      [ "$verdict" = PASS ] || failed=$((failed + 1))
      # Any of these may be missing (a failed run, or a single-VM test without cp_node).
      echo_=$(grep -aoE 'HOMA_(SMOKE|PAIR)_ECHO responses=[0-9]+' "$out" | head -n 1 | sed 's/.*=//' || true)
      gro=$(grep -aoE 'homa_gro_receive calls=[0-9]+' "$out" | head -n 1 | sed 's/.*=//' || true)
      homa=$(grep -a 'HOMA_PAIR_CPNODE_homa ' "$out" | tail -n 1 || true)
      tcp=$(grep -a 'HOMA_PAIR_CPNODE_tcp ' "$out" | tail -n 1 || true)
      printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
        "$name" "$kernels" "$verdict" "$secs" "''${echo_:-0}/6" "''${gro:-—}" \
        "$(field "$homa" clients:)" "$(field "$homa" P50) / $(field "$homa" P99)" \
        "$(field "$tcp" clients:)" "$(field "$tcp" P50) / $(field "$tcp" P99)" >> "$summary"
    }
    ${lib.concatMapStrings (t: ''
      row ${t.name} ${lib.escapeShellArg t.kernels}
    '') tests}

    echo
    cat "$summary"
    echo
    echo "summary: $summary ($(( $(date +%s) - start )) s)"
    if [ "$failed" -gt 0 ]; then
      echo "VERDICT: FAIL ($failed of ${toString (builtins.length tests)})"
      exit 1
    fi
    echo "VERDICT: PASS (${toString (builtins.length tests)} of ${toString (builtins.length tests)})"
  '';
}
