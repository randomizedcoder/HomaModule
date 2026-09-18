# nix/fuzz/tools/fuzz-deep.nix
#
# Longer fork-mode run over the standalone harness set, seeded with the committed corpus and
# steered by the wire dictionary, with crashes de-duplicated by ASan SUMMARY signature
# (rocm-systems pattern). Env knobs: FUZZ_DEEP_TIME, FUZZ_DEEP_FORKS, FUZZ_DEEP_MAXLEN.

{ pkgs, lib, src, fuzz, symbolizer }:

pkgs.stdenv.mkDerivation {
  pname = "homa-fuzz-deep";
  version = "0";
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.gnugrep ];

  buildPhase = ''
    export ASAN_SYMBOLIZER_PATH="${symbolizer}"
    export ASAN_OPTIONS="abort_on_error=0:detect_leaks=0:symbolize=1"
    time="''${FUZZ_DEEP_TIME:-60}"
    forks="''${FUZZ_DEEP_FORKS:-2}"
    maxlen="''${FUZZ_DEEP_MAXLEN:-4096}"
    dict="${src}/nix/fuzz/dict/homa_wire.dict"
    work="$PWD/work"; mkdir -p "$work"
    for bin in ${fuzz}/bin/fuzz_*; do
      name="$(basename "$bin")"
      mkdir -p "$work/$name"
      cp -r ${fuzz}/corpus/"$name"/* "$work/$name/" 2>/dev/null || true
      "$bin" -fork="$forks" -ignore_crashes=1 -max_len="$maxlen" -dict="$dict" \
        -max_total_time="$time" -artifact_prefix="$work/$name/" "$work/$name" \
        > "$work/$name.log" 2>&1 || true
    done
  '';

  installPhase = ''
    mkdir -p "$out" "$out/crashes"
    total=0; distinct=0
    {
      echo "=== Homa fuzz-deep (fork mode + dict + signature dedup) ==="
      for bin in ${fuzz}/bin/fuzz_*; do
        name="$(basename "$bin")"
        declare -A seen=()
        n=0
        while IFS= read -r c; do
          [ -n "$c" ] || continue
          n=$((n+1)); total=$((total+1))
          sig=$(ASAN_OPTIONS=symbolize=1 "$bin" "$c" 2>&1 | grep -m1 -oE 'SUMMARY: .*' | sed 's/0x[0-9a-f]*//g')
          [ -n "$sig" ] || sig="unknown-$n"
          h=$(printf '%s' "$sig" | cksum | cut -d' ' -f1)
          if [ -z "''${seen[$h]:-}" ]; then
            seen[$h]=1; distinct=$((distinct+1))
            mkdir -p "$out/crashes/$name"
            cp "$c" "$out/crashes/$name/crash-sig-$h" 2>/dev/null || true
            ASAN_OPTIONS=symbolize=1 "$bin" "$c" > "$out/crashes/$name/repro-sig-$h.txt" 2>&1 || true
          fi
        done < <(find "work/$name" -name 'crash-*' 2>/dev/null)
        printf '  %-20s %s crash(es)\n' "$name:" "$n"
        unset seen
      done
      echo ""
      echo "Total crashes: $total   Distinct signatures: $distinct"
    } > "$out/summary.txt"
    echo "$distinct" > "$out/distinct_count.txt"
    echo "$total" > "$out/count.txt"
    cat "$out/summary.txt"
  '';
  dontFixup = true;
}
