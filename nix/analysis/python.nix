# nix/analysis/python.nix
#
# Python static analysis with ruff. Homa's scripts include EXTENSIONLESS python programs
# (util/cp_* with a `#!/usr/bin/python3` shebang), so files are discovered by shebang as
# well as by `.py` extension — a plain `*.py` glob would miss them.

{ pkgs, homaLib, mkAnalysisTool }:

mkAnalysisTool {
  name = "python";
  tools = [ pkgs.ruff ];
  src = homaLib.src.all;
  script = ''
    export RUFF_CACHE_DIR="$TMPDIR/ruff"
    # A shebang must be the first line (grep -l would match a "#!" on any line).
    { find . -type f -exec awk 'FNR == 1 && /^#!.*python/ { print FILENAME } { nextfile }' {} +
      find . -name '*.py'; } | sort -u > "$out/files.txt"
    mapfile -t pyfiles < "$out/files.txt"
    {
      echo "# ruff check ($(wc -l < "$out/files.txt") files)"
      if [ "''${#pyfiles[@]}" -gt 0 ]; then
        ruff check --output-format=concise "''${pyfiles[@]}" 2>&1 || true
      fi
    } > "$out/report.txt"
  '';
  # ruff's concise format: path:line:col: code message
  count = "^[^:]+:[0-9]+:[0-9]+:";
}
