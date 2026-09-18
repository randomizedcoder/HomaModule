# nix/analysis/python.nix
#
# Python static analysis with ruff. Homa's scripts include EXTENSIONLESS python programs
# (util/cp_* with a `#!/usr/bin/python3` shebang), so files are discovered by shebang as
# well as by `.py` extension — a plain `*.py` glob would miss them.
#
# Emits $out/report.txt (full ruff output) and $out/count.txt (number of findings).

{ pkgs, lib, src }:

pkgs.runCommand "homa-analysis-python"
{
  nativeBuildInputs = [ pkgs.ruff pkgs.coreutils pkgs.gnugrep pkgs.findutils ];
} ''
  cp -r ${src} src && chmod -R +w src && cd src
  mkdir -p "$out"
  export RUFF_CACHE_DIR="$TMPDIR/ruff"

  # Discover python files: shebang-based + *.py, excluding .git.
  { grep -rlE '^#!.*python' . 2>/dev/null || true; find . -name '*.py' 2>/dev/null || true; } \
    | grep -vE '/\.git/' | sort -u > "$out/files.txt"
  mapfile -t pyfiles < "$out/files.txt"

  {
    echo "# ruff check ($(wc -l < "$out/files.txt") files)"
    if [ "''${#pyfiles[@]}" -gt 0 ]; then
      ruff check --output-format=concise "''${pyfiles[@]}" 2>&1 || true
    fi
  } > "$out/report.txt"

  # Count concise "path:line:col:" findings.
  count=$(grep -cE '^[^:]+:[0-9]+:[0-9]+:' "$out/report.txt" || true)
  echo "''${count:-0}" > "$out/count.txt"
''
