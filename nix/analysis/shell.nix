# nix/analysis/shell.nix
#
# Shell static analysis with shellcheck + shfmt. Homa has NO *.sh files — its shell scripts
# are extensionless (util/send_many, util/get_traces, cloudlab/bin/*), so discovery is by
# shebang.
#
# Emits $out/report.txt and $out/count.txt.

{ pkgs, lib, src }:

pkgs.runCommand "homa-analysis-shell"
{
  nativeBuildInputs = [ pkgs.shellcheck pkgs.shfmt pkgs.coreutils pkgs.gnugrep pkgs.findutils ];
} ''
  cp -r ${src} src && chmod -R +w src && cd src
  mkdir -p "$out"

  # Discover shell scripts by shebang (sh/bash), excluding .git.
  grep -rlE '^#!.*(bash|/bin/sh|env sh)' . 2>/dev/null \
    | grep -vE '/\.git/' | sort -u > "$out/files.txt"
  mapfile -t shfiles < "$out/files.txt"

  {
    echo "# shellcheck ($(wc -l < "$out/files.txt") files)"
    if [ "''${#shfiles[@]}" -gt 0 ]; then
      shellcheck --severity=warning "''${shfiles[@]}" 2>&1 || true
    fi
    echo ""
    echo "# shfmt -d (formatting diffs)"
    if [ "''${#shfiles[@]}" -gt 0 ]; then
      shfmt -d "''${shfiles[@]}" 2>&1 || true
    fi
  } > "$out/report.txt"

  # Count shellcheck "In ... line N:" occurrences.
  count=$(grep -cE '^In .* line [0-9]+:' "$out/report.txt" || true)
  echo "''${count:-0}" > "$out/count.txt"
''
