# nix/parts/build.nix
#
# homa.ko for every kernel (and cross-compiled on x86_64 hosts), the util/ tools, the unit
# tests, and the OCI image. `nix build` with no target builds homa-module.

{
  perSystem = { homa, lib, system, ... }: {
    packages =
      homa.modulePkgs.packages
      // homa.userspacePkgs.packages
      // homa.ociPkgs.packages
      # The cross toolchains are built for x86_64 hosts only.
      // lib.optionalAttrs (system == "x86_64-linux") homa.crossPkgs.packages
      // { default = homa.modulePkgs.homa-module; };
  };
}
