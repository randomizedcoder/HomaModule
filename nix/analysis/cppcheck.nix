# nix/analysis/cppcheck.nix
#
# cppcheck over the core C sources. Runs standalone (no compile DB needed) so it stays in
# the `standard` tier without requiring a kernel build. Kernel headers are absent, so many
# macros are unknown — we suppress missingInclude/unknownMacro noise and focus on cppcheck's
# own flow/bounds/leak checks.
#
# Emits $out/report.txt and $out/count.txt.

{ pkgs, lib, src }:

pkgs.runCommand "homa-analysis-cppcheck"
{
  nativeBuildInputs = [ pkgs.cppcheck pkgs.coreutils pkgs.findutils pkgs.gnugrep ];
} ''
  cp -r ${src} src && chmod -R +w src && cd src
  mkdir -p "$out"

  mapfile -t cfiles < <(find . -maxdepth 1 -type f -name 'homa_*.c' | sort)
  cfiles+=("./timetrace.c")

  cppcheck \
    --enable=warning,performance,portability \
    --std=c11 \
    --language=c \
    -I. \
    --suppress=missingInclude \
    --suppress=missingIncludeSystem \
    --suppress=unknownMacro \
    --inline-suppr \
    --quiet \
    --template='{file}:{line}: {severity}: {id}: {message}' \
    "''${cfiles[@]}" 2> "$out/report.txt" || true

  count=$(grep -cE '^[^:]+:[0-9]+: ' "$out/report.txt" || true)
  # Prepend a header without clobbering findings.
  { echo "# cppcheck (warning,performance,portability; std=c11): $count finding(s)"; cat "$out/report.txt"; } \
    > "$out/report.txt.tmp" && mv "$out/report.txt.tmp" "$out/report.txt"
  echo "''${count:-0}" > "$out/count.txt"
''
