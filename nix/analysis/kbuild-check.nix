# nix/analysis/kbuild-check.nix
#
# A checker that kbuild runs on every source file (make C=2 CHECK=...), against the default
# kernel: sparse and smatch (deep tier). Best-effort: if the module does not build against
# that kernel, the report still holds what the checker and kbuild printed. But it fails if
# kbuild never ran the checker at all (no "CHECK" line), so a broken setup cannot pass as
# zero findings.
#
#   kbuildCheck { name, checker, flags ? "", count }
#     checker  the command kbuild runs per file (CHECK=)
#     flags    passed to it (CF=)
#     count    extended regex for one finding in its output

{ kernelConfig, mkAnalysisTool }:

{ name, checker, flags ? "", count }:

mkAnalysisTool {
  inherit name count;
  tools = [ ];
  kbuild = true;
  script = ''
    # C=2 checks every file, not just those make rebuilds.
    make KDIR=${kernelConfig.kdir} MY_CFLAGS='-O2' \
      C=2 CHECK="${checker}" CF="${flags}" > checker.stdout.log 2> checker.stderr.log || true
    {
      echo "# ${name} ${flags}"
      cat checker.stderr.log checker.stdout.log
    } > "$out/report.txt"
    if ! grep -qE '^ +CHECK ' checker.stdout.log; then
      cat "$out/report.txt"
      echo "${name}: kbuild never ran the checker"
      exit 1
    fi
  '';
}
