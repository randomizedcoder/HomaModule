# nix/analysis/default.nix
#
# Tiered static analysis (xdp2/rocm pattern). Each tool module is a derivation that writes
# $out/report.txt + $out/count.txt; the tier targets link those together and emit a
# summary.txt with per-tool finding counts.
#
#   analysis-quick     python (ruff) + shell (shellcheck/shfmt) + clang-format   (no kernel)
#   analysis-standard  + cppcheck + clang-tidy (compile DB)
#   analysis-deep      + sparse (endianness) + smatch
#
# Per-tool packages are also exposed (analysis-ruff, analysis-cppcheck, ...).
#
# Usage in flake.nix:
#   analysisPkgs = import ./nix/analysis { inherit pkgs lib kernelConfig; src = self; };

{ pkgs
, lib
, kernelConfig
, src
}:

let
  python = import ./python.nix { inherit pkgs lib src; };
  shell = import ./shell.nix { inherit pkgs lib src; };
  clang-format = import ./clang-format.nix { inherit pkgs lib src; };
  cppcheck = import ./cppcheck.nix { inherit pkgs lib src; };
  compile-db = import ./compile-db.nix { inherit pkgs lib src kernelConfig; };
  clang-tidy = import ./clang-tidy.nix { inherit pkgs lib src compile-db; };
  sparse = import ./sparse.nix { inherit pkgs lib src kernelConfig; };
  smatch = import ./smatch.nix { inherit pkgs lib src kernelConfig; };

  # A tier is a runCommand that gathers named tool reports into one directory + summary.
  mkTier = tierName: tools:
    let
      links = lib.concatMapStringsSep "\n"
        (t: ''
          if [ -e "${t.drv}/report.txt" ]; then
            cp "${t.drv}/report.txt" "$out/${t.name}.report.txt"
            c=$(cat "${t.drv}/count.txt" 2>/dev/null || echo 0)
          else
            c=0
          fi
          printf '  %-14s %s finding(s)\n' "${t.name}:" "$c" >> "$out/summary.txt"
          total=$((total + c))
        '')
        tools;
    in
    pkgs.runCommand "homa-${tierName}" { } ''
      mkdir -p "$out"
      total=0
      echo "=== Homa ${tierName} ===" > "$out/summary.txt"
      ${links}
      echo "" >> "$out/summary.txt"
      echo "Total: $total finding(s)" >> "$out/summary.txt"
      echo "$total" > "$out/count.txt"
      cat "$out/summary.txt"
    '';

  quickTools = [
    { name = "ruff"; drv = python; }
    { name = "shell"; drv = shell; }
    { name = "clang-format"; drv = clang-format; }
  ];
  standardTools = quickTools ++ [
    { name = "cppcheck"; drv = cppcheck; }
    { name = "clang-tidy"; drv = clang-tidy; }
  ];
  deepTools = standardTools ++ [
    { name = "sparse"; drv = sparse; }
  ] ++ lib.optional (pkgs ? smatch) { name = "smatch"; drv = smatch; };

  analysis-quick = mkTier "analysis-quick" quickTools;
  analysis-standard = mkTier "analysis-standard" standardTools;
  analysis-deep = mkTier "analysis-deep" deepTools;
in
{
  packages = {
    inherit analysis-quick analysis-standard analysis-deep;
    analysis-ruff = python;
    analysis-shell = shell;
    analysis-clang-format = clang-format;
    analysis-cppcheck = cppcheck;
    analysis-clang-tidy = clang-tidy;
    analysis-compile-db = compile-db;
    analysis-sparse = sparse;
  } // lib.optionalAttrs (pkgs ? smatch) { analysis-smatch = smatch; };

  # `analysis-quick` is kernel-independent, so it makes a good `nix flake check` gate.
  checks = { inherit analysis-quick; };
}
