# nix/analysis/default.nix
#
# Tiered static analysis (xdp2/rocm pattern). Each tool is one mkAnalysisTool call (below)
# that writes $out/report.txt and $out/count.txt; the tier targets gather those into one
# summary.txt with per-tool finding counts.
#
#   analysis-quick     python (ruff) + shell (shellcheck/shfmt) + clang-format   (no kernel)
#   analysis-standard  + cppcheck + clang-tidy (compile DB)
#   analysis-deep      + sparse (endianness) + smatch
#
# Per-tool packages are also exposed (analysis-ruff, analysis-cppcheck, ...). nix/scope.nix
# calls this file with callPackage; each tool file is called the same way, and gets
# mkAnalysisTool.

{ pkgs
, lib
, homaLib
, kernelConfig
}:

let
  # mkAnalysisTool { name, tools, script, count, src?, kbuild? }: copies the source (by
  # default Homa's module sources), runs script, which writes "$out/report.txt", then
  # writes into count.txt how many report lines match the extended regex count.
  # kbuild = true adds what a build against the default kernel needs, a C compiler
  # included (runCommandCC; plain runCommand has none).
  mkAnalysisTool = { name, tools, script, count, src ? homaLib.src.module, kbuild ? false }:
    (if kbuild then pkgs.runCommandCC else pkgs.runCommand) "homa-analysis-${name}"
      {
        nativeBuildInputs = with pkgs; [ coreutils findutils gnugrep gnused ] ++ tools
          ++ lib.optionals kbuild
          ([ pkgs.gnumake ] ++ kernelConfig.kernelPackages.kernel.moduleBuildDependencies);
        hardeningDisable = lib.optional kbuild "all";
      } ''
      cp -r ${src} src && chmod -R +w src && cd src
      mkdir -p "$out"
      ${script}
      count=$(grep -cE '${count}' "$out/report.txt" || true)
      echo "''${count:-0}" > "$out/count.txt"
    '';

  # callPackageWith: like callPackage, with these added to what a file can name.
  call = lib.callPackageWith (pkgs // { inherit homaLib kernelConfig mkAnalysisTool; });
  kbuildCheck = call ./kbuild-check.nix { };

  python = call ./python.nix { };
  shell = call ./shell.nix { };
  clang-format = call ./clang-format.nix { };
  cppcheck = call ./cppcheck.nix { };
  compile-db = call ./compile-db.nix { };
  clang-tidy = call ./clang-tidy.nix { inherit compile-db; };
  # sparse: the kernel's own semantic checker, with endianness checks on. It flags
  # mismatched __be16/__be32/__be64 handling and __force casts in the wire code, which
  # fuzzing can miss.
  sparse = kbuildCheck {
    name = "sparse";
    checker = "${pkgs.sparse}/bin/sparse";
    flags = "-D__CHECK_ENDIAN__ -Wsparse-all";
    count = ":[0-9]+:[0-9]+: (warning|error):";
  };
  # smatch: kernel-oriented flow analysis, when nixpkgs has it.
  smatch = kbuildCheck {
    name = "smatch";
    checker = "${pkgs.smatch}/bin/smatch -p=kernel";
    count = ":[0-9]+:[0-9]+: (warn|error):";
  };
  hasSmatch = pkgs ? smatch;

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
  ] ++ lib.optional hasSmatch { name = "smatch"; drv = smatch; };

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
  } // lib.optionalAttrs hasSmatch { analysis-smatch = smatch; };

  # `analysis-quick` is kernel-independent, so it makes a good `nix flake check` gate.
  checks = { inherit analysis-quick; };
}
