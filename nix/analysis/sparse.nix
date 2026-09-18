# nix/analysis/sparse.nix
#
# sparse — the kernel-specific semantic checker — run through kbuild with ENDIANNESS
# checking on (`-D__CHECK_ENDIAN__`). This is the *static* complement to the fuzzing focus
# on (de)serialization: it flags mismatched __be16/__be32/__be64 handling and __force casts
# across homa_wire.h / homa_incoming.c / homa_outgoing.c that dynamic fuzzing can miss.
#
# Kernel-dependent (deep tier). Best-effort: if the module doesn't build against the pinned
# kernel, the log still captures what sparse/kbuild reported.
#
# Emits $out/report.txt and $out/count.txt.

{ pkgs, lib, src, kernelConfig }:

pkgs.stdenv.mkDerivation {
  pname = "homa-analysis-sparse";
  version = "0";
  inherit src;

  nativeBuildInputs = [ pkgs.gnumake pkgs.sparse ]
    ++ kernelConfig.kernelPackages.kernel.moduleBuildDependencies;
  hardeningDisable = [ "all" ];
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    # C=2 forces re-check of all files; CHECK=sparse selects the checker; CF passes flags.
    make KDIR=${kernelConfig.kdir} MY_CFLAGS='-O2' \
      C=2 CHECK="${pkgs.sparse}/bin/sparse" \
      CF="-D__CHECK_ENDIAN__ -Wsparse-all" \
      > sparse.stdout.log 2> sparse.stderr.log || true
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    {
      echo "# sparse (-D__CHECK_ENDIAN__ -Wsparse-all)"
      echo "## stderr (warnings/errors)"
      cat sparse.stderr.log 2>/dev/null || true
    } > "$out/report.txt"
    # sparse messages look like "file:line:col: warning: ..." / "error:".
    count=$(grep -cE ':[0-9]+:[0-9]+: (warning|error):' "$out/report.txt" || true)
    echo "''${count:-0}" > "$out/count.txt"
    runHook postInstall
  '';

  dontFixup = true;
}
