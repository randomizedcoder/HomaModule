#
# flake.nix for Homa (HomaModule) — a modular Nix layer over the out-of-tree kernel module.
#
# Design & rationale:  nix/docs/DESIGN.md
# Status + findings:   nix/STATUS.md
# Quick start:         nix/README.md
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
#   HOMA_LINUX_SRC=~/Downloads/linux nix build --impure .#homa-module-local
#   nix build .#homa-utils                 # user-space tools from util/
#   nix build .#homa-utils-debug           # user-space tools with AddressSanitizer
#   nix build .#homa-tests                 # build + run the unit tests (ASan)
#
#   nix run   .#homa-microvm-test          # boot a microVM, insmod homa.ko, loopback echo RPCs
#   nix run   .#homa-microvm-test-6_12     # ... per VM kernel: 6_12 7_3 (kernel.nix vmSeries)
#   nix run   .#homa-microvm-test-debug    # ... under a KASAN/KMEMLEAK kernel
#   nix run   .#homa-lifecycle[-6_12]      # timed phases driven over ttyS0 + a virtio console
#   nix run   .#homa-pair-test             # two VMs: echo + cp_node (Homa, TCP) over a link
#   nix run   .#homa-pair-test-6_12-7_3    # ... server kernel, client kernel (every pairing)
#   nix run   .#homa-pair-exp              # latency sweep (sysctls x workloads, metric deltas)
#   nix run   .#homa-vm-matrix             # every VM test + pair in parallel, summary table
#
#   nix build .#homa-image                 # OCI userspace image  (docker load < result)
#   nix build .#homa-image-debug
#
#   nix build .#analysis-quick             # python + shell + clang-format (no kernel needed)
#   nix build .#analysis-standard          # + clang-tidy + cppcheck
#   nix build .#analysis-deep              # + sparse (endian) + smatch + checkpatch
#
#   nix build .#fuzz                       # build all libFuzzer harnesses
#   FUZZ_TIME=300 ./result/bin/run-fuzzers #   ... then run them for 5 min
#   nix build .#fuzz-run                   # bounded run -> summary.txt / count.txt / crashes
#   nix build .#fuzz-deep                  # fork-mode + dictionary + crash dedup
#   nix build .#fuzz-cov                   # coverage of the wire (de)serialization functions
#   nix build .#fuzz-selftest              # canary gate (fails if the harness is vacuous)
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
    flake-utils.url = "github:numtide/flake-utils";
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, microvm }:
    # Homa is a Linux kernel module; restrict to Linux systems (nixpkgs unstable also no
    # longer supports x86_64-darwin).
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = nixpkgs.lib;

        # ── Foundation modules (config → attrsets/fragments) ───────────────────────────
        kernelConfig = import ./nix/kernel.nix { inherit pkgs lib; };
        packagesModule = import ./nix/packages.nix {
          inherit pkgs lib;
          kernelPackages = kernelConfig.kernelPackages;
        };
        pythonEnv = packagesModule.pythonEnv;
        envVars = import ./nix/env-vars.nix { inherit pkgs lib kernelConfig pythonEnv; };
        shellFunctions = import ./nix/shell-functions { inherit pkgs lib; };

        # Homa source with any forward-port patches in nix/patches/ applied (currently none).
        # Every derivation builds this, not `self` directly.
        homaSrc = import ./nix/patches { inherit pkgs; src = self; };
        # Kernel trees prepared from kernel.org tarballs (7.0-7.2) or a local checkout.
        kernelSrc = import ./nix/kernel-src.nix { inherit pkgs lib; };

        # ── Derivation modules ─────────────────────────────────────────────────────────
        modulePkgs = import ./nix/module.nix {
          inherit pkgs lib kernelConfig kernelSrc;
          src = homaSrc;
        };
        # Cross-compile checks for riscv64 and aarch64 (x86_64 hosts only).
        crossPkgs = import ./nix/cross.nix {
          inherit pkgs lib kernelConfig kernelSrc;
          src = homaSrc;
          buildAgainstTree = modulePkgs.buildAgainstTree;
        };
        userspacePkgs = import ./nix/userspace.nix {
          inherit pkgs lib kernelConfig;
          src = homaSrc;
        };
        ociPkgs = import ./nix/oci.nix {
          inherit pkgs lib pythonEnv;
          homa-utils = userspacePkgs.homa-utils;
          homa-utils-debug = userspacePkgs.homa-utils-debug;
        };
        analysisPkgs = import ./nix/analysis {
          inherit pkgs lib kernelConfig;
          src = homaSrc;
        };
        fuzzPkgs = import ./nix/fuzz {
          inherit pkgs lib kernelConfig;
          src = homaSrc;
        };
        microvmPkgs = import ./nix/microvms {
          inherit pkgs lib microvm nixpkgs kernelConfig;
          buildSystem = system;
          buildModule = modulePkgs.buildModule;
          homaUtils = userspacePkgs.homa-utils;
        };
      in
      {
        devShells.default = import ./nix/devshell.nix {
          inherit pkgs lib packagesModule envVars shellFunctions;
        };

        packages =
          modulePkgs.packages
          // userspacePkgs.packages
          // ociPkgs.packages
          // analysisPkgs.packages
          // fuzzPkgs.packages
          // microvmPkgs.packages
          // lib.optionalAttrs (system == "x86_64-linux") crossPkgs.packages
          // { default = modulePkgs.homa-module; };

        checks =
          analysisPkgs.checks or { }
          // fuzzPkgs.checks or { };

        formatter = pkgs.nixpkgs-fmt;
      });
}
