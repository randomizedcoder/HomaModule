#!/usr/bin/env bats
# Bug 10 — put a fake `ssh` on PATH that prints "<host>: <args>" so we can
# observe how many argv words on_nodes actually forwards.

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  cat >"$STUBS/ssh" <<'EOF'
#!/usr/bin/env bash
shift 2          # drop -4 and the host flag pair as on_nodes passes them
printf '%s: %s\n' "$1" "$*"
EOF
  chmod +x "$STUBS/ssh"
  PATH="$STUBS:$PATH"
}

@test "single command"     { run on_nodes 1 1 uptime
                             [ "$output" = "node1: uptime" ]; }

@test "no extra args"      { run on_nodes 1 1
                             [ "$output" = "node1: " ]; }

@test "quoted multi-word"  { run on_nodes 1 1 "grep foo bar"
                             [ "$output" = "node1: grep foo bar" ]; }

@test "glob stays literal" { run on_nodes 1 1 "ls *.log"
                             [ "$output" = "node1: ls *.log" ]; }
