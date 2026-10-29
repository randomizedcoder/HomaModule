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
#
# pairNode = "server" | "client" makes the guest one half of the two-VM pair test: a second
# NIC (eth1) on a QEMU socket link to the other guest, a static IP, cp_node's node<N>
# hostnames, and pair.nix's script in place of the smoke test.

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
, pairNode ? null     # null | "server" | "client"
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

  pair = constants.pair;
  isPair = pairNode != null;
  node = pair.nodes.${pairNode};
  pairScripts = import ./pair.nix { inherit pkgs homaKoPath homaUtils pair; };
  testScript = if isPair then pairScripts.${pairNode} else smoke;
  testExe = lib.getExe testScript;

  guest = nixpkgs.lib.nixosSystem {
    system = buildSystem;
    modules = [
      microvm.nixosModules.microvm
      ({ config, pkgs, lib, ... }: {
        boot.kernelPackages = guestKernelPackages;
        boot.kernelParams = [
          "console=ttyS0,115200"
          "systemd.show_status=true"
        ] ++ lib.optionals isPair [
          # Stable names: the user NIC is eth0 and the pair link eth1.
          "net.ifnames=0"
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

          # Pair link (eth1): point-to-point QEMU socket, node0 listens and node1 connects.
          qemu.extraArgs = lib.optionals isPair [
            "-netdev"
            "socket,id=homapair,${node.role}=127.0.0.1:${toString pair.socketPort}"
            "-device"
            "virtio-net-pci,netdev=homapair,mac=${node.mac}"
          ];
        };

        networking.interfaces = lib.mkIf isPair {
          eth1 = {
            useDHCP = false;
            ipv4.addresses = [{ address = node.ip; inherit (pair) prefixLength; }];
          };
        };
        networking.hosts = lib.mkIf isPair (lib.mapAttrs'
          (_: n: lib.nameValuePair n.ip [ n.hostname ])
          pair.nodes);
        # The NixOS firewall would drop Homa (IP protocol 146) and the coordination ports.
        networking.firewall.enable = !isPair;

        # Interactive use: passwordless root autologin on the console.
        services.getty.autologinUser = "root";
        users.users.root.password = "";

        networking.hostName = if isPair then node.hostname else constants.hostname;

        environment.systemPackages = [ pkgs.kmod pkgs.iproute2 pkgs.coreutils homaUtils testScript ];
        environment.variables.HOMA_KO = homaKoPath;

        systemd.services.homa-test = lib.mkIf autoTest {
          wantedBy = [ "multi-user.target" ];
          after = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            StandardOutput = "journal+console";
            StandardError = "journal+console";
            ExecStart = testExe;
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
