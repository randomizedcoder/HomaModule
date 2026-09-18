# nix/fuzz/tools/fuzz-mock.nix
#
# Builds the KERNEL-MOCK libFuzzer harnesses (Focus A: per-packet-type parse + dispatch +
# gro; Focus B: roundtrip + differential) by reusing Homa's user-space mock layer
# (test/mock.c) the way the unit tests do, but compiled with clang + libFuzzer instead of
# gcc + ASan. It mirrors test/Makefile's include/def flags.
#
# This is kernel-header dependent and clang-vs-kernel-headers sensitive (see docs/DESIGN.md
# §5,§7). It is written to be NON-FATAL: every compile/link is best-effort and the outcome
# (which harnesses built) is recorded in $out/status.txt, so a kernel/clang mismatch on the
# newest kernel is reported rather than failing the whole flake. Built binaries land in
# $out/bin, seed corpora in $out/corpus.

{ pkgs, lib, src, kernelConfig, sanFlags, symbolizer }:

let
  moduleSrcs = [
    "homa_devel" "homa_interest" "homa_incoming" "homa_outgoing" "homa_peer"
    "homa_pool" "homa_plumbing" "homa_rpc" "homa_sock" "homa_timer"
    "homa_tx_pool" "homa_utils" "timetrace"
    "homa_grant" "homa_hijack" "homa_metrics" "homa_offload" "homa_qdisc"
  ];
  mockHarnesses = [
    "deser/fuzz_dispatch" "deser/fuzz_data_pkt" "deser/fuzz_grant_pkt"
    "deser/fuzz_resend_pkt" "deser/fuzz_ack_pkt" "deser/fuzz_cutoffs_pkt"
    "deser/fuzz_need_ack_pkt" "deser/fuzz_rpc_unknown_pkt" "deser/fuzz_gro"
    "roundtrip/fuzz_roundtrip" "roundtrip/fuzz_differential"
  ];
in
pkgs.stdenv.mkDerivation {
  pname = "homa-fuzzers-mock";
  version = "0";
  inherit src;
  nativeBuildInputs = [ pkgs.clang pkgs.gnumake ]
    ++ kernelConfig.kernelPackages.kernel.moduleBuildDependencies;
  hardeningDisable = [ "all" ];
  dontConfigure = true;

  KDIR = kernelConfig.kdir;

  buildPhase = ''
    runHook preBuild
    set +e
    mkdir -p obj out/bin out/corpus
    : > out/status.txt

    # nixpkgs splits the kernel tree: $KDIR (build) holds generated headers, the sibling
    # source/ tree holds the checked-in headers (include/linux/kconfig.h, arch uapi, ...).
    # Mirror kbuild by spanning both.
    SRC="$(dirname "$KDIR")/source"
    KERN_INCLUDES="-I$SRC/arch/x86/include -I$KDIR/arch/x86/include/generated \
      -I$SRC/include -I$KDIR/include \
      -I$SRC/arch/x86/include/uapi -I$KDIR/arch/x86/include/generated/uapi \
      -I$SRC/include/uapi -I$KDIR/include/generated/uapi"
    INC="-Itest -I. -Inix/fuzz/harness $KERN_INCLUDES -include $SRC/include/linux/kconfig.h"
    DEFS="-D__KERNEL__ -D__UNIT_TEST__ -DKBUILD_MODNAME=\"homa\""
    CBASE="-fsanitize=fuzzer-no-link,address,undefined -g -O1 -fno-omit-frame-pointer -w $DEFS $INC"
    CCBASE="-std=c++17 -fsanitize=fuzzer-no-link,address,undefined -g -O1 -fno-omit-frame-pointer -w $DEFS $INC"

    ok=1
    cc_c()  { clang   -c $CBASE  "$1" -o "$2" 2>> out/build.log || { echo "FAILED C  $1"  >> out/status.txt; ok=0; }; }
    cc_cc() { clang++ -c $CCBASE "$1" -o "$2" 2>> out/build.log || { echo "FAILED CC $1"  >> out/status.txt; ok=0; }; }

    # Module sources (repo root).
    shared=""
    for m in ${lib.concatStringsSep " " moduleSrcs}; do
      cc_c "$m.c" "obj/$m.o"; shared="$shared obj/$m.o"
    done
    # Vendored data structures (rhashtable needs -O2 and no ASan per test/Makefile).
    cc_c "test/rbtree.c" "obj/rbtree.o"; shared="$shared obj/rbtree.o"
    clang -c $CBASE -O2 -fno-sanitize=address test/rhashtable.c -o obj/rhashtable.o 2>> out/build.log \
      || { echo "FAILED C test/rhashtable.c" >> out/status.txt; ok=0; }
    shared="$shared obj/rhashtable.o"
    # Mock + support.
    cc_c  "test/mock.c"    "obj/mock.o";    shared="$shared obj/mock.o"
    cc_c  "test/utils.c"   "obj/utils.o";   shared="$shared obj/utils.o"
    cc_cc "test/ccutils.cc" "obj/ccutils.o"; shared="$shared obj/ccutils.o"

    if [ "$ok" != "1" ]; then
      echo "shared objects failed to compile against ${kernelConfig.modDirVersion}; harnesses skipped" >> out/status.txt
    else
      echo "shared objects OK against ${kernelConfig.modDirVersion}" >> out/status.txt
      for h in ${lib.concatStringsSep " " mockHarnesses}; do
        base="$(basename "$h")"
        if clang++ -c $CCBASE "nix/fuzz/harness/$h.cc" -o "obj/$base.o" 2>> out/build.log; then
          if clang++ ${sanFlags} $shared "obj/$base.o" -o "out/bin/$base" 2>> out/build.log; then
            echo "BUILT $base" >> out/status.txt
            seed="nix/fuzz/corpus-seeds/''${base#fuzz_}"
            mkdir -p "out/corpus/$base"
            [ -d "$seed" ] && cp "$seed"/* "out/corpus/$base/" 2>/dev/null || true
          else
            echo "LINK-FAILED $base" >> out/status.txt
          fi
        else
          echo "COMPILE-FAILED $base" >> out/status.txt
        fi
      done
    fi

    echo "--- status ---"; cat out/status.txt
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r out/* "$out/"
    # Never fail: this target's job is to report what built.
    runHook postInstall
  '';
  dontFixup = true;
}
