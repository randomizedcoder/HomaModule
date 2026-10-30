# nix/parts/vms.nix
#
# The QEMU guests and the tests that drive them (../microvms); tcl-tests is a check.

{
  perSystem = { homa, ... }: {
    inherit (homa.microvmPkgs) packages checks;
  };
}
