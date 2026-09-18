# nix/kernel.nix
#
# Single source of truth for kernel selection.
#
# Returns the default kernelPackages (nixpkgs `linux_latest`, overridable), the derived
# KDIR / modDirVersion used by the out-of-tree module build, and a small LTS "matrix" used
# for compile-testing homa.ko against older kernels when the newest kernel drifts from what
# Homa `main` targets (~6.17). See docs/DESIGN.md §5.
#
# Usage in flake.nix:
#   kernelConfig = import ./nix/kernel.nix { inherit pkgs lib; };
#   kernelConfig.kernelPackages   # default (linux_latest)
#   kernelConfig.kdir             # "${kernel.dev}/lib/modules/${modDirVersion}/build"
#   kernelConfig.matrix           # { "6_12" = <kernelPackages>; ... } (only those present)

{ pkgs
, lib
  # Override the default kernel by passing another kernelPackages set.
  #
  # Default = 6.12 LTS: it is the newest kernel in this nixpkgs that actually builds Homa.
  # `main` targets ~6.17 (now EOL-removed from nixpkgs), and nixpkgs `linux_latest` (7.2.x)
  # fails to build the module (upstream API drift, not a flake bug — see docs/STATUS.md).
  # `latest` below is still exposed so the drift can be reproduced / re-checked over time.
, kernelPackages ? pkgs.linuxPackages_6_12
}:

let
  kernel = kernelPackages.kernel;
  modDirVersion = kernel.modDirVersion;

  # KDIR for a given kernelPackages: the build tree shipped in the kernel's `dev` output.
  kdirOf = kp: "${kp.kernel.dev}/lib/modules/${kp.kernel.modDirVersion}/build";

  # Compile-test matrix: candidate kernelPackages by version. Some attrs exist but throw on
  # access (EOL kernels), so each is probed with tryEval and only usable ones are kept.
  candidateNames = [ "6_1" "6_6" "6_12" "6_16" "6_17" ];
  kpFor = name: pkgs."linuxPackages_${name}" or null;
  usable = name:
    let
      kp = kpFor name;
      probe = builtins.tryEval (kp != null && builtins.isString kp.kernel.modDirVersion);
    in
    probe.success && probe.value;
  matrix = lib.listToAttrs
    (map (n: lib.nameValuePair n (kpFor n)) (lib.filter usable candidateNames));
in
{
  inherit kernelPackages kernel modDirVersion matrix kdirOf;
  kdir = kdirOf kernelPackages;
  # nixpkgs newest kernel (exposed for the drift-demonstration target; may fail to build).
  latest = pkgs.linuxPackages_latest;
}
