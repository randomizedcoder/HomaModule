#
# flake.nix for Homa (HomaModule) — a modular Nix layer over the out-of-tree kernel module.
#
# ── Usage ──────────────────────────────────────────────────────────────────────────────
#   nix develop                            # dev shell (toolchain + analysis tools)
#
#   nix build .#homa-module                # build homa.ko (release) against the pinned kernel
#   nix build .#homa-module-debug          # build homa.ko (debug: -g -O1)
#   nix build .#homa-module-6_12           # per kernel: 6_1 6_6 6_12 6_18 7_3 (nixpkgs),
#                                          #   7_0 7_1 7_2 (kernel.org source, compile only)
#   nix build .#homa-build-matrix          # every kernel above -> summary.md (never fails)
#   nix build .#homa-module-riscv64        # cross-compiled homa.ko: riscv64, aarch64 (+ -strip)
#   nix build .#homa-cross-matrix          # both arches: homa.ko + util/ report -> summary.md
#   nix build .#linux-kdir-riscv64-7_3     # the prepared kernel tree a cross build uses (+ aarch64)
#   HOMA_LINUX_SRC=~/Downloads/linux nix build --impure .#homa-module-local
#   nix build .#homa-utils                 # user-space tools from util/
#   nix build .#homa-utils-debug           # user-space tools with AddressSanitizer
#   nix build .#homa-tests                 # build + run the unit tests (ASan)
#
#   nix build .#homa-image                 # OCI userspace image  (docker load < result)
#   nix build .#homa-image-debug
#
#   nix flake show                         # list every output
#   nix flake check                        # evaluate/build the checks
#
# If flakes are not enabled globally:
#   nix --extra-experimental-features 'nix-command flakes' develop .
# ───────────────────────────────────────────────────────────────────────────────────────
{
  description = "Homa: modular Nix flake (module + userspace derivations, microVM, static analysis, fuzzing)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # flake-parts merges the modules in nix/parts/, one per area, each adding its packages
  # and checks for every system (nix/parts/README.md). nix/scope.nix builds the
  # derivations themselves.
  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Homa is a Linux kernel module; restrict to Linux systems (nixpkgs unstable also no
      # longer supports x86_64-darwin).
      systems = [ "x86_64-linux" "aarch64-linux" ];
      imports = [
        ./nix/parts/scope.nix
        ./nix/parts/build.nix
        ./nix/parts/dev.nix
      ];
    };
}
