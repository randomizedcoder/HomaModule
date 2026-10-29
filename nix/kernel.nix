# nix/kernel.nix
#
# Single source of truth for kernel selection.
#
# Returns the default kernelPackages (nixpkgs `linux_latest`, overridable), the derived
# KDIR / modDirVersion used by the out-of-tree module build, and a "matrix" of every kernel
# series nixpkgs ships (6.1 ... 7.3), used for per-kernel module builds and microVMs.
#
# Usage in flake.nix:
#   kernelConfig = import ./nix/kernel.nix { inherit pkgs lib; };
#   kernelConfig.kernelPackages   # default (nixpkgs linux_latest, 7.3)
#   kernelConfig.kdir             # "${kernel.dev}/lib/modules/${modDirVersion}/build"
#   kernelConfig.matrix           # { "6_1" = <kp>; ...; "7_3" = <kp>; } (only those present)
#   kernelConfig.unitKdir         # KDIR for the unit harness / mock fuzzers (6.18)

{ pkgs
, lib
  # Override the default kernel by passing another kernelPackages set.
  #
  # Default = nixpkgs' newest kernel (7.3 at the time of writing): Homa is being ported
  # forward to 7.x. Upstream `main` builds here since the 7.1 port landed (e65a5c0).
, kernelPackages ? pkgs.linuxPackages_latest
  # The unit harness and kernel-mock fuzzers need a kernel whose headers test/mock.c
  # supports; kept separate so it can lag the default.
, unitKernelPackages ? pkgs.linuxPackages_6_18
}:

let
  kernel = kernelPackages.kernel;
  modDirVersion = kernel.modDirVersion;

  # KDIR for a given kernelPackages: the build tree shipped in the kernel's `dev` output.
  kdirOf = kp: "${kp.kernel.dev}/lib/modules/${kp.kernel.modDirVersion}/build";

  # "7.3.1" -> "7_3"
  seriesOf = kp: lib.replaceStrings [ "." ] [ "_" ] (lib.versions.majorMinor kp.kernel.version);

  # Matrix: every kernel series nixpkgs still ships, keyed by series. Some attrs exist but
  # throw on access (EOL kernels), so each is probed with tryEval and only usable ones kept.
  # Series nixpkgs has dropped (7.0-7.2) come from kernel.org tarballs: see kernel-src.nix.
  candidates = [ "6_1" "6_6" "6_12" "6_18" "latest" ];
  kpFor = name: pkgs."linuxPackages_${name}" or null;
  usable = name:
    let
      kp = kpFor name;
      probe = builtins.tryEval (kp != null && builtins.isString kp.kernel.modDirVersion);
    in
    probe.success && probe.value;
  matrix = lib.listToAttrs
    (map (n: lib.nameValuePair (seriesOf (kpFor n)) (kpFor n)) (lib.filter usable candidates));
in
{
  inherit kernelPackages kernel modDirVersion matrix kdirOf seriesOf unitKernelPackages;
  kdir = kdirOf kernelPackages;
  unitKdir = kdirOf unitKernelPackages;
  unitModDirVersion = unitKernelPackages.kernel.modDirVersion;
  latest = pkgs.linuxPackages_latest;
}
