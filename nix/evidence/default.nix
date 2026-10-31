# nix/evidence/default.nix
#
# One report of everything the flake checks, for reviewers and demos:
#
#   homa-evidence        nix build .#homa-evidence: every check that needs no VM (kernel
#                        build matrix, cross builds, unit tests and their coverage, static
#                        analysis including netdev's checks, fuzzing), gathered into
#                        evidence.md and evidence.html, with each check's own output beside
#                        them
#   homa-evidence-full   nix run .#homa-evidence-full -- [outdir]: that report, plus the VM
#                        matrix (homa-vm-matrix, needs KVM) and, with HOMA_EVIDENCE_SANITIZERS=1,
#                        the pair lifecycle on the KASAN and KCSAN kernels
#
# The report only gathers results; each section comes from a derivation that the flake
# also exposes on its own, so any number in it can be rebuilt and checked by itself.

{ pkgs
, lib
, modulePkgs
, crossPkgs
, userspacePkgs
, analysisPkgs
, fuzzPkgs
, microvmPkgs
}:

let
  hasCross = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
  m = modulePkgs.packages;
  a = analysisPkgs.packages;
  f = fuzzPkgs.packages;
  v = microvmPkgs.packages;
  coverage = userspacePkgs.packages.homa-tests-coverage;

  # Markdown to a standalone page (light and dark).
  toHtml = ''
    to_html() {
      {
        printf '%s\n' '<!doctype html><html><head><meta charset="utf-8">' \
          '<meta name="viewport" content="width=device-width, initial-scale=1">' \
          '<title>Homa evidence</title><style>' \
          ':root{color-scheme:light dark;--fg:#1d1d1f;--bg:#fff;--muted:#f2f2f4;--line:#d8d8dc}' \
          '@media (prefers-color-scheme:dark){:root{--fg:#e6e6e8;--bg:#16161a;--muted:#222228;--line:#3a3a42}}' \
          'body{font:15px/1.5 system-ui,sans-serif;color:var(--fg);background:var(--bg);max-width:1100px;margin:0 auto;padding:16px}' \
          'table{border-collapse:collapse;margin:8px 0;display:block;overflow-x:auto}' \
          'td,th{border:1px solid var(--line);padding:4px 8px;text-align:left}' \
          'pre{background:var(--muted);padding:12px;overflow-x:auto;font-size:13px}' \
          'code{font-size:13px}</style></head><body>'
        cmark-gfm -e table "$1"
        echo '</body></html>'
      } > "$2"
    }
  '';

  homa-evidence = pkgs.runCommand "homa-evidence"
    { nativeBuildInputs = with pkgs; [ jq cmark-gfm ]; } ''
    mkdir -p "$out"
    cov=${coverage}/coverage.json
    pct() { jq -r ".$1" "$cov"; }
    # kernels <series prefix> <result regex>: rows of the build matrix that match.
    kernels() { grep -cE "^\| $1[^|]* \|[^|]*\| ($2) \|" ${m.homa-build-matrix}/summary.md || true; }
    units=$(grep -oE '[0-9]+ / [0-9]+ tests passed' ${coverage}/unit.log | tail -n 1)
    # "ruff 1973, shell 4, ..." from a tier's summary.txt.
    tools() { awk '/^ +[a-z].*finding/ { sub(":", "", $1); printf "%s%s %s", sep, $1, $2; sep = ", " }' "$1"; }
    crashes=$(sed -nE 's/^Total crash inputs: ([0-9]+).*/\1/p' ${f.fuzz-run}/summary.txt)
    harnesses=$(grep -cF 'crash input(s)' ${f.fuzz-run}/summary.txt || true)

    {
      echo "# Homa: evidence report"
      echo
      echo "Built by \`nix build .#homa-evidence\` from the flake's pinned inputs. Every section"
      echo "is also a flake output of its own (named in its heading), so each result can be"
      echo "rebuilt and checked by itself."
      echo
      echo "## At a glance"
      echo
      echo "| Area | Result |"
      echo "|---|---|"
      echo "| homa.ko builds, 7.x kernels (\`main\` targets 7.3+) | $(kernels 7 PASS) of $(kernels 7 'PASS|FAIL') |"
      echo "| homa.ko builds, older kernels (API drift expected) | $(kernels 6 PASS) of $(kernels 6 'PASS|FAIL') |"
      ${lib.optionalString hasCross ''
        echo "| homa.ko builds (architectures) | x86_64, aarch64, riscv64 |"
      ''}
      echo "| Unit tests | $units |"
      echo "| Unit-test coverage of Homa's sources | lines $(pct line_percent) %, branches $(pct branch_percent) %, functions $(pct function_percent) % |"
      echo "| Static analysis, raw findings (\`analysis-deep\`) | $(tools ${a.analysis-deep}/summary.txt) |"
      echo "| netdev checks on the code as submitted (\`analysis-netdev\`) | $(tools ${a.analysis-netdev}/summary.txt) |"
      echo "| Fuzzing (\`fuzz-run\`) | ''${crashes:-?} crash inputs from $harnesses harnesses; $(cut -d: -f1 ${f.fuzz-selftest}/verdict.txt) (the canary finds an injected overflow) |"
      echo
      echo "## Kernels (\`homa-build-matrix\`)"
      echo
      cat ${m.homa-build-matrix}/summary.md
      ${lib.optionalString hasCross ''
        echo
        echo "## Architectures (\`homa-cross-matrix\`)"
        echo
        sed 's/^# /### /; s/^## /#### /' ${crossPkgs.packages.homa-cross-matrix}/summary.md
      ''}
      echo
      echo "## Unit tests and coverage (\`homa-tests-coverage\`)"
      echo
      echo "Line coverage per file; html/ has every source line annotated."
      echo
      echo '```'
      tail -n 4 ${coverage}/unit.log
      echo
      cat ${coverage}/lines.txt
      echo '```'
      echo
      echo "## Static analysis (\`analysis-deep\`)"
      echo
      echo "Raw counts, before triage: most are style (ruff on util/'s Python, clang-tidy's"
      echo "readability checks) or sparse's notes on kernel headers. The triaged findings, and"
      echo "the upstream fixes they led to, are in analysis-reports/ on the fork."
      echo
      echo '```'
      cat ${a.analysis-deep}/summary.txt
      echo '```'
      echo
      echo "## netdev checks (\`analysis-netdev\`)"
      echo
      echo "checkpatch --strict, kernel-doc and in-tree W=1 builds (gcc with sparse, clang,"
      echo "32-bit) of the files \`make net-next\` writes, as a submission would carry them."
      echo
      echo '```'
      cat ${a.analysis-netdev}/summary.txt
      echo
      cat ${a.analysis-netdev}/gcc-w1.report.txt
      echo
      cat ${a.analysis-netdev}/kdoc.report.txt
      echo '```'
      echo
      echo "checkpatch's report: analysis-netdev/checkpatch.report.txt."
      echo
      echo "## Fuzzing (\`fuzz-run\`, \`fuzz-cov\`, \`fuzz-selftest\`)"
      echo
      echo '```'
      cat ${f.fuzz-run}/summary.txt
      echo
      tail -n 5 ${f.fuzz-cov}/summary.txt
      echo
      cat ${f.fuzz-selftest}/verdict.txt
      echo '```'
    } > "$out/evidence.md"

    ${toHtml}
    to_html "$out/evidence.md" "$out/evidence.html"

    # Each check's own output, for the details.
    ln -s ${coverage}/html "$out/coverage-html"
    ln -s ${a.analysis-deep} "$out/analysis-deep"
    ln -s ${a.analysis-netdev} "$out/analysis-netdev"
    ln -s ${f.fuzz-run} "$out/fuzz-run"
    ln -s ${m.homa-build-matrix} "$out/build-matrix"
    cat "$out/evidence.md"
  '';

  homa-evidence-full = pkgs.writeShellApplication {
    name = "homa-evidence-full";
    runtimeInputs = with pkgs; [ coreutils cmark-gfm ];
    text = ''
      out=$(realpath -m "''${1:-homa-evidence-out}")
      mkdir -p "$out"
      cp -rL --no-preserve=mode ${homa-evidence}/. "$out/"
      md="$out/evidence.md"
      # vm <title> <command> <logdir>: run one VM test command, append its summary.
      vm() {
        local status=0
        echo "== $1"
        HOMA_VM_LOGDIR="$3" "$2" || status=$?
        {
          echo
          echo "## $1 (\`$(basename "$2")\`)"
          echo
          if [ -f "$3/summary.md" ]; then cat "$3/summary.md"; fi
          echo
          echo "Exit status: $status. Logs: $3"
        } >> "$md"
      }
      vm "VM tests: every kernel, pairs across kernels" ${lib.getExe v.homa-vm-matrix} "$out/vm"
      if [ "''${HOMA_EVIDENCE_SANITIZERS:-0}" = 1 ]; then
        vm "Pair lifecycle on a KASAN/lockdep/UBSAN kernel" \
          ${lib.getExe v.homa-pair-lifecycle-debug} "$out/vm-kasan"
        vm "Pair lifecycle on a KCSAN kernel" \
          ${lib.getExe v.homa-pair-lifecycle-kcsan} "$out/vm-kcsan"
      fi
      ${toHtml}
      to_html "$md" "$out/evidence.html"
      echo "Report: $out/evidence.html"
    '';
  };
in
{
  packages = { inherit homa-evidence homa-evidence-full; };
}
