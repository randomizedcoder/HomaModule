# nix/analysis/smatch.nix
#
# smatch — kernel-oriented flow analysis — run through kbuild (deep tier). Only wired when
# nixpkgs provides `smatch` (guarded in analysis/default.nix). Best-effort, like sparse.
#
# Emits $out/report.txt and $out/count.txt.

{ pkgs, lib, src, kernelConfig }:

pkgs.stdenv.mkDerivation {
  pname = "homa-analysis-smatch";
  version = "0";
  inherit src;

  nativeBuildInputs = [ pkgs.gnumake pkgs.smatch ]
    ++ kernelConfig.kernelPackages.kernel.moduleBuildDependencies;
  hardeningDisable = [ "all" ];
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    make KDIR=${kernelConfig.kdir} MY_CFLAGS='-O2' \
      C=2 CHECK="${pkgs.smatch}/bin/smatch -p=kernel" \
      > smatch.stdout.log 2> smatch.stderr.log || true
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    {
      echo "# smatch (-p=kernel)"
      cat smatch.stderr.log 2>/dev/null || true
      cat smatch.stdout.log 2>/dev/null || true
    } > "$out/report.txt"
    count=$(grep -cE ':[0-9]+:[0-9]+: (warn|error):' "$out/report.txt" || true)
    echo "''${count:-0}" > "$out/count.txt"
    runHook postInstall
  '';

  dontFixup = true;
}
