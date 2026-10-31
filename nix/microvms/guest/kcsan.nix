# nix/microvms/guest/kcsan.nix
#
# For the KCSAN guest (debug-kernels.nix): a udev rule that runs when homa.ko is loaded. It
# limits KCSAN's reports to Homa's functions (the debugfs "whitelist" of every function
# /proc/kallsyms lists for [homa]), then turns KCSAN on. The kernel boots with KCSAN off, so
# data races in the rest of the kernel never reach the console. A reload adds the new
# addresses; KCSAN keeps the old ones, which match nothing once Homa is gone.
#
# The rule runs asynchronously, a moment after insmod, so the first few RPCs of a run may go
# unwatched.

{ pkgs }:

let
  arm = pkgs.writeShellApplication {
    name = "homa-kcsan-arm";
    runtimeInputs = with pkgs; [ coreutils gawk ];
    text = ''
      ctl=/sys/kernel/debug/kcsan
      echo whitelist > "$ctl"
      n=0
      while read -r f; do
        echo "!$f" > "$ctl"
        n=$((n + 1))
      done < <(awk '$4 == "[homa]" && $2 ~ /^[tT]$/ { print $3 }' /proc/kallsyms)
      echo on > "$ctl"
      echo "homa-kcsan: watching $n Homa functions" > /dev/kmsg
    '';
  };
in
''
  ACTION=="add", SUBSYSTEM=="module", KERNEL=="homa", RUN+="${pkgs.lib.getExe arm}"
''
