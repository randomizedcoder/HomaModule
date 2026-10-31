# nix/analysis/cppcheck.nix
#
# cppcheck over the core C sources. Runs standalone (no compile DB needed) so it stays in
# the `standard` tier without requiring a kernel build. Kernel headers are absent, so many
# macros are unknown — we suppress missingInclude/unknownMacro noise and focus on cppcheck's
# own flow/bounds/leak checks.

{ pkgs, mkAnalysisTool }:

mkAnalysisTool {
  name = "cppcheck";
  tools = [ pkgs.cppcheck ];
  script = ''
    mapfile -t cfiles < <(find . -maxdepth 1 -type f -name 'homa_*.c' | sort)
    cfiles+=("./timetrace.c")
    {
      echo "# cppcheck (warning,performance,portability; std=c11)"
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
        "''${cfiles[@]}" 2>&1 || true
    } > "$out/report.txt"
  '';
  count = "^[^:]+:[0-9]+: ";
}
