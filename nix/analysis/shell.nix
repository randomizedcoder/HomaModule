# nix/analysis/shell.nix
#
# Shell static analysis with shellcheck + shfmt. Homa has NO *.sh files — its shell scripts
# are extensionless (util/send_many, util/get_traces, cloudlab/bin/*), so discovery is by
# shebang.

{ pkgs, homaLib, mkAnalysisTool }:

mkAnalysisTool {
  name = "shell";
  tools = [ pkgs.shellcheck pkgs.shfmt ];
  src = homaLib.src.all;
  script = ''
    # The shebang must be the first line (grep -l would match a "#!" on any line).
    find . -type f -exec awk 'FNR == 1 && /^#!.*(bash|\/bin\/sh|env sh)/ { print FILENAME }
      { nextfile }' {} + | sort -u > "$out/files.txt"
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
  '';
  # One per shellcheck finding: "In <file> line N:"
  count = "^In .* line [0-9]+:";
}
