# nix/analysis/clang-format.nix
#
# clang-format compliance check for the core C sources/headers. Homa follows Linux kernel
# style (tabs, checkpatch-strict), so we check against the built-in LinuxKernel style rather
# than imposing a new one (avoids massive churn).

{ pkgs, mkAnalysisTool }:

mkAnalysisTool {
  name = "clang-format";
  tools = [ pkgs.clang-tools ];
  script = ''
    # Core module sources/headers (top-level homa_*.c/.h + timetrace).
    mapfile -t cfiles < <(find . -maxdepth 1 -type f \( -name 'homa_*.c' -o -name 'homa_*.h' \
        -o -name 'homa.h' -o -name 'timetrace.c' -o -name 'timetrace.h' \) | sort)
    {
      echo "# clang-format (style=LinuxKernel): ''${#cfiles[@]} files checked"
      for f in "''${cfiles[@]}"; do
        clang-format --style=LinuxKernel --dry-run --Werror "$f" >/dev/null 2>&1 \
          || echo "would-reformat: $f"
      done
    } > "$out/report.txt"
  '';
  count = "^would-reformat: ";
}
