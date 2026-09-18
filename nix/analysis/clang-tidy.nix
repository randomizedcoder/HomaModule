# nix/analysis/clang-tidy.nix
#
# clang-tidy over the core C sources using the compile DB from compile-db.nix. The DB's
# absolute paths (from the compile-db build sandbox) are rewritten onto this copy of the
# tree. Kernel-code clang-tidy via a captured DB is inherently best-effort; if the DB is
# empty (module didn't build) this yields 0 findings, which is recorded honestly.
#
# Emits $out/report.txt and $out/count.txt.

{ pkgs, lib, src, compile-db }:

pkgs.runCommand "homa-analysis-clang-tidy"
{
  nativeBuildInputs = [ pkgs.clang-tools pkgs.jq pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
} ''
  cp -r ${src} src && chmod -R +w src && cd src
  mkdir -p "$out"

  # Rewrite the DB's recorded source root onto our copy so clang-tidy finds the files.
  srcroot=$(cat ${compile-db}/srcroot 2>/dev/null || echo /nonexistent)
  sed "s|$srcroot|$PWD|g" ${compile-db}/compile_commands.json > compile_commands.json

  mapfile -t files < <(jq -r '.[].file' compile_commands.json 2>/dev/null \
    | sed "s|$srcroot|$PWD|g" | grep -E 'homa_.*\.c$' | sort -u || true)

  {
    echo "# clang-tidy (bugprone-*,cert-*,clang-analyzer-*): ''${#files[@]} file(s) in DB"
    for f in "''${files[@]}"; do
      [ -f "$f" ] || continue
      clang-tidy -p "$PWD" \
        --checks='-*,bugprone-*,cert-*,clang-analyzer-*,misc-*' \
        "$f" 2>&1 || true
    done
  } > "$out/report.txt"

  count=$(grep -cE ': (warning|error): ' "$out/report.txt" || true)
  echo "''${count:-0}" > "$out/count.txt"
''
