# nix/microvms/constants.nix
#
# Pure data shared by the guest builder (mkVm.nix) and the orchestrator (lib.nix). Single
# source of truth for ports, identity, kernel selection, and timeouts (uds-rdma-proxy pattern).

{ lib }:

{
  hostname = "homa-vm";

  # TCP port where the guest serial console is exposed on the host (expect connects here).
  consoleSerialPort = 7101;

  # Guest resources.
  vcpu = 2;
  mem = 2048;        # MiB, normal build
  memDebug = 4096;   # KASAN needs headroom

  # Orchestration timeouts (seconds).
  bootTimeout = 180;
  bootTimeoutDebug = 2400;   # first debug run also builds a KASAN kernel
  cmdTimeout = 60;

  # Kernel used for BOTH guest boot and the co-pinned homa.ko build (avoids vermagic drift).
  # Matches kernel.nix's default; the guest builder derives KASAN from this for the debug VM.
  kernelPackage = "linuxPackages_latest";

  stateVersion = "24.11";
}
