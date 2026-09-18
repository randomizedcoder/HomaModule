# nix/analysis/clang-format.nix
#
# clang-format compliance check for the core C sources/headers. Homa follows Linux kernel
# style (tabs, checkpatch-strict), so we check against the built-in LinuxKernel style rather
# than imposing a new one (avoids massive churn).
#
# Emits $out/report.txt (files that would change) and $out/count.txt (their number).

{ pkgs, lib, src }:

pkgs.runCommand "homa-analysis-clang-format"
{
  nativeBuildInputs = [ pkgs.clang-tools pkgs.coreutils pkgs.findutils ];
} ''
  cp -r ${src} src && chmod -R +w src && cd src
  mkdir -p "$out"

  # Core module sources/headers (top-level homa_*.c/.h + timetrace).
  mapfile -t cfiles < <(find . -maxdepth 1 -type f \( -name 'homa_*.c' -o -name 'homa_*.h' \
      -o -name 'homa.h' -o -name 'timetrace.c' -o -name 'timetrace.h' \) | sort)

  : > "$out/report.txt"
  count=0
  for f in "''${cfiles[@]}"; do
    if ! clang-format --style=LinuxKernel --dry-run --Werror "$f" >/dev/null 2>>"$out/report.txt"; then
      echo "would-reformat: $f" >> "$out/report.txt"
      count=$((count + 1))
    fi
  done
  echo "# clang-format (style=LinuxKernel): $count of ''${#cfiles[@]} files would change" \
    | cat - "$out/report.txt" > "$out/report.txt.tmp" && mv "$out/report.txt.tmp" "$out/report.txt"
  echo "$count" > "$out/count.txt"
''
