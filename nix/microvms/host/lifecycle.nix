# nix/microvms/host/lifecycle.nix
#
# Lifecycle test (pcp/xdp2 pattern): the host boots a guest with two consoles (mkVm.nix
# consolePorts) and drives it phase by phase, with a timeout and a time for each. The
# driver is tcl/bin/lifecycle.tcl (Tcl/Expect, see tcl/README.md); this file only gives it
# its configuration:
#
#   1  start      qemu running, console ports listening
#   2  serial     first kernel line in serial.log (ttyS0, 115200 baud, logged from the start)
#   2b virtio     a root shell answering on hvc0 (the fast virtio console)
#   3  smoke      homa-smoke (smoke.nix) over hvc0: insmod, echo, GRO/RPS, rmmod
#   4  cycles     insmod / netns add+del / rmmod, moduleCycles times (pernet init and exit)
#   5  dmesg      no BUG/Oops/WARNING/KASAN/UBSAN in the guest's dmesg, read over hvc0
#   6  shutdown   poweroff over hvc0
#   7  exit       qemu exits
#   8  serial-log no oops anywhere in serial.log, including after the shell has gone
#                 (late RCU callbacks: STATUS.md F8)
#
# The phase table is printed and written to summary.md; the last line is the VERDICT. Logs
# are in $HOMA_VM_LOGDIR (default: a fresh mktemp -d), which is also qemu's working
# directory.

{ lib
, constants
, tclApps         # tcl.nix
, runner          # config.microvm.declaredRunner for a guest built with consolePorts
, consolePorts    # { serial; virtio; }
, label ? ""
}:

let
  lc = constants.lifecycle;
in
tclApps.mkTclApp {
  name = "homa-lifecycle${label}";
  driver = "lifecycle.tcl";
  config = {
    inherit label;
    inherit (lc) timeouts moduleCycles;
    vm = consolePorts // { runner = "${runner}"; };
  };
}
