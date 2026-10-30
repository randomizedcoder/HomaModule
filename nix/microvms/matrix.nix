# nix/microvms/matrix.nix
#
# One command for every VM test (PLAN-pairs.md phase 3): runs each per-kernel single-VM
# smoke test and each (server, client) pair test in parallel, then prints a summary table
# (also written to $logdir/summary.md):
#
#   | Test | Kernel(s) | Verdict | Time (s) | Echo | GRO calls | Homa Kops/s | Homa P50 / P99 (us) | TCP ... |
#
# Each test keeps its own console logs and output under $HOMA_VM_LOGDIR/<test>/. The tests
# share nothing on the host (each pair has its own link port), so they can all run at once;
# HOMA_VM_JOBS caps how many run together (default: all). Exits non-zero if any test fails.
# The driver is tcl/bin/vm-matrix.tcl (see tcl/README.md); this file gives it the tests.

{ lib
, tclApps   # tcl.nix
, tests     # list of { name, kernels, exe }: exe is a homa-microvm-test-* or homa-pair-test-* package
}:

tclApps.mkTclApp {
  name = "homa-vm-matrix";
  driver = "vm-matrix.tcl";
  config.tests = map (t: { inherit (t) name kernels; exe = lib.getExe t.exe; }) tests;
}
