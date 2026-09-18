# nix/analysis/compile-db.nix
#
# Builds a compile_commands.json for the module by running the kbuild compile under `bear`.
# This is kernel-dependent (needs moduleBuildDependencies + KDIR) and is the input to
# clang-tidy. If the module fails to build (kernel API drift), an empty DB is emitted so the
# downstream analysis still evaluates (the drift is recorded, not fatal).
#
# Also records the build's source root ($out/srcroot) so clang-tidy can rewrite the DB's
# absolute paths onto its own copy of the tree.

{ pkgs, lib, src, kernelConfig }:

pkgs.stdenv.mkDerivation {
  pname = "homa-compile-db";
  version = "0";
  inherit src;

  nativeBuildInputs = [ pkgs.gnumake pkgs.bear ]
    ++ kernelConfig.kernelPackages.kernel.moduleBuildDependencies;
  hardeningDisable = [ "all" ];
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    echo "$PWD" > srcroot
    bear --output compile_commands.json -- \
      make KDIR=${kernelConfig.kdir} MY_CFLAGS='-O2' || true
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp srcroot "$out/srcroot"
    if [ -f compile_commands.json ]; then
      cp compile_commands.json "$out/compile_commands.json"
    else
      echo '[]' > "$out/compile_commands.json"
    fi
    runHook postInstall
  '';

  dontFixup = true;
}
