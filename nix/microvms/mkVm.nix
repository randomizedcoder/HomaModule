# nix/microvms/mkVm.nix
#
# Parameterised microVM guest (uds-rdma-proxy pattern). Builds a NixOS guest that imports the
# microvm.nix module, boots the SAME kernelPackages the homa.ko was built against (co-pinning
# avoids "vermagic" drift), mounts the host /nix/store over 9p so the .ko store path is
# visible in the guest, and exports it as $HOMA_KO. Evaluates to the QEMU runner package
# (config.microvm.declaredRunner).
#
# withSanitizers=true builds a KASAN/KMEMLEAK kernel for the debug VM (heavy: rebuilds the
# kernel).

{ pkgs
, lib
, microvm
, nixpkgs
, kernelConfig
, buildSystem
, constants
, homaModule          # release homa.ko derivation
, homaModuleDebug     # debug homa.ko derivation
, homaUtils ? null    # optional: user-space tools to bake in
, withSanitizers ? false
}:

let
  baseKernelPackages = kernelConfig.kernelPackages;

  # For the debug VM, turn on KASAN/KMEMLEAK by overriding the kernel config.
  sanitizerKernel = (baseKernelPackages.kernel.override {
    structuredExtraConfig = with lib.kernel; {
      KASAN = yes;
      KASAN_GENERIC = yes;
      KASAN_INLINE = yes;
      DEBUG_KMEMLEAK = yes;
      KCOV = yes;
    };
  });
  sanitizerKernelPackages = pkgs.linuxPackagesFor sanitizerKernel;

  kernelPackages = if withSanitizers then sanitizerKernelPackages else baseKernelPackages;

  # Co-pinned module: use the matching build. (For the sanitizer kernel we still load the
  # debug .ko; its vermagic matches because modDirVersion is unchanged by config-only overrides.)
  homaKo = if withSanitizers then homaModuleDebug else homaModule;
  modVer = kernelConfig.modDirVersion;
  homaKoPath = "${homaKo}/lib/modules/${modVer}/homa.ko";

  guest = nixpkgs.lib.nixosSystem {
    system = buildSystem;
    modules = [
      microvm.nixosModules.microvm
      ({ config, pkgs, lib, ... }: {
        boot.kernelPackages = kernelPackages;
        boot.kernelParams = lib.optionals withSanitizers [ "kmemleak=on" "kasan_multi_shot" ];

        microvm = {
          hypervisor = "qemu";
          vcpu = constants.vcpu;
          mem = if withSanitizers then constants.memDebug else constants.mem;

          # Host /nix/store visible in the guest, so $HOMA_KO resolves.
          shares = [{
            source = "/nix/store";
            mountPoint = "/nix/store";
            tag = "nix-store";
            proto = "9p";
          }];

          # Minimal NAT interface (needed only so the store mount/init works).
          interfaces = [{
            type = "user";
            id = "eth0";
            mac = "52:54:00:00:00:01";
          }];

          # Expose the serial console over TCP so the orchestrator's expect script can drive it.
          qemu.extraArgs = [
            "-serial" "tcp:127.0.0.1:${toString constants.consoleSerialPort},server,nowait"
          ];
        };

        # Passwordless root autologin so expect matches a prompt with no password step.
        services.getty.autologinUser = "root";
        users.users.root.password = "";

        networking.hostName = constants.hostname;

        environment.systemPackages = [ pkgs.kmod pkgs.iproute2 pkgs.coreutils ]
          ++ lib.optional (homaUtils != null) homaUtils;
        environment.variables.HOMA_KO = homaKoPath;

        # Trim NixOS bloat for a fast microVM.
        documentation.enable = false;
        documentation.nixos.enable = false;
        nix.enable = false;
        system.stateVersion = constants.stateVersion;
      })
    ];
  };
in
guest.config.microvm.declaredRunner
