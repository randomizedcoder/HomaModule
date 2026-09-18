# nix/oci.nix
#
# A lightweight OCI image bundling Homa's user-space tools + Python tooling (secondary to
# the microVM, which is the real kernel-module test vehicle). Uses dockerTools.buildLayeredImage
# (reproducible, layer-cached) per the xdp2 pattern.
#
#   nix build .#homa-image        && docker load < result
#   nix build .#homa-image-debug  && docker load < result
#
# Usage in flake.nix:
#   ociPkgs = import ./nix/oci.nix {
#     inherit pkgs lib pythonEnv;
#     inherit (userspacePkgs) homa-utils homa-utils-debug;
#   };

{ pkgs
, lib
, pythonEnv
, homa-utils
, homa-utils-debug
}:

let
  mkImage = { name, utils }:
    pkgs.dockerTools.buildLayeredImage {
      inherit name;
      tag = "latest";
      created = "1970-01-01T00:00:00Z"; # reproducible

      contents = [
        utils
        pythonEnv
        pkgs.bashInteractive
        pkgs.coreutils
      ];

      config = {
        Cmd = [ "/bin/bash" ];
        Env = [ "MPLBACKEND=Agg" ];
        Labels = {
          "org.opencontainers.image.title" = name;
          "org.opencontainers.image.description" =
            "Homa user-space tools and Python analysis tooling";
          "org.opencontainers.image.source" =
            "https://github.com/PlatformLab/HomaModule";
          "org.opencontainers.image.licenses" = "BSD-2-Clause";
        };
      };
    };

  homa-image = mkImage { name = "homa-image"; utils = homa-utils; };
  homa-image-debug = mkImage { name = "homa-image-debug"; utils = homa-utils-debug; };
in
{
  inherit homa-image homa-image-debug;
  packages = { inherit homa-image homa-image-debug; };
}
