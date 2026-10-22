# nix/microvms/mkVm.nix
#
# Parameterised microVM guest (uds-rdma-proxy pattern). Builds a NixOS guest that imports the
# microvm.nix module, boots the SAME kernelPackages the homa.ko was built against (co-pinning
# avoids "vermagic" drift), mounts the host /nix/store over 9p so the .ko store path is
# visible in the guest, and exports it as $HOMA_KO. Evaluates to the QEMU runner package
# (config.microvm.declaredRunner).
#
# autoTest=true runs the smoke test (smoke.nix) at boot as a systemd oneshot, with its output
# on the serial console, then powers the VM off: lib.nix only has to capture and grep the
# console (xtcp2 pattern). autoTest=false gives an interactive VM with root autologin.
#
# withSanitizers=true builds a KASAN/KMEMLEAK kernel for the debug VM (heavy: rebuilds the
# kernel).
#
# kernelPackages selects the guest kernel (one VM per kernel.nix matrix entry, xtcp2-style).

{ pkgs
, lib
, microvm
, nixpkgs
, kernelPackages      # guest kernel; homaModule must be built against it
, buildSystem
, constants
, homaModule          # release homa.ko derivation
, homaModuleDebug     # debug homa.ko derivation
, homaUtils           # user-space tools (demo_server1/demo_client1 for the smoke test)
, withSanitizers ? false
, autoTest ? false
}:

let
  baseKernelPackages = kernelPackages;

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

  guestKernelPackages = if withSanitizers then sanitizerKernelPackages else baseKernelPackages;

  # Co-pinned module: use the matching build. (For the sanitizer kernel we still load the
  # debug .ko; its vermagic matches because modDirVersion is unchanged by config-only overrides.)
  homaKo = if withSanitizers then homaModuleDebug else homaModule;
  modVer = baseKernelPackages.kernel.modDirVersion;
  homaKoPath = "${homaKo}/lib/modules/${modVer}/homa.ko";

  smoke = import ./smoke.nix { inherit pkgs homaKoPath homaUtils withSanitizers; };

  guest = nixpkgs.lib.nixosSystem {
    system = buildSystem;
    modules = [
      microvm.nixosModules.microvm
      ({ config, pkgs, lib, ... }: {
        boot.kernelPackages = guestKernelPackages;
        boot.kernelParams = [
          "console=ttyS0,115200"
          "systemd.show_status=true"
        ] ++ lib.optionals withSanitizers [ "kmemleak=on" "kasan_multi_shot" ];
        boot.initrd.availableKernelModules = [ "9p" "9pnet" "9pnet_virtio" "virtio_pci" ];

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

          # The "pc" machine (as in xtcp2): on qemu's default "microvm" machine the guest's
          # 8250 UART never registers as ttyS0, so the console goes silent after early boot.
          qemu.machine = "pc";

          # Minimal NAT interface (needed only so the store mount/init works).
          interfaces = [{
            type = "user";
            id = "eth0";
            mac = "52:54:00:00:00:01";
          }];
        };

        # Interactive use: passwordless root autologin on the console.
        services.getty.autologinUser = "root";
        users.users.root.password = "";

        networking.hostName = constants.hostname;

        environment.systemPackages = [ pkgs.kmod pkgs.iproute2 pkgs.coreutils homaUtils smoke ];
        environment.variables.HOMA_KO = homaKoPath;

        systemd.services.homa-smoke = lib.mkIf autoTest {
          wantedBy = [ "multi-user.target" ];
          after = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            StandardOutput = "journal+console";
            StandardError = "journal+console";
            ExecStart = "${smoke}/bin/homa-smoke";
            # Pass or fail, end the run so the host sees qemu exit.
            ExecStopPost = "${pkgs.systemd}/bin/systemctl poweroff --no-block";
          };
        };

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
