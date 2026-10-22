# nix/microvms/constants.nix
#
# Pure data shared by the guest builder (mkVm.nix) and the orchestrator (lib.nix). Single
# source of truth for identity, resources and timeouts (uds-rdma-proxy pattern).

{ lib }:

{
  hostname = "homa-vm";

  # Guest resources.
  vcpu = 2;
  mem = 2048; # MiB, normal build
  memDebug = 4096; # KASAN needs headroom

  # Whole-run timeouts (seconds): boot + smoke test + poweroff. The kernels are chosen in
  # kernel.nix (default and matrix), not here.
  bootTimeout = 300;
  bootTimeoutDebug = 1200; # KASAN guests boot slowly

  stateVersion = "24.11";
}
