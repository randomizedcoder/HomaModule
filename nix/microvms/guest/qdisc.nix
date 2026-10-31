# nix/microvms/guest/qdisc.nix
#
# homa-qdisc on|off|show (guest command): attach Homa's queuing discipline to every tx
# queue of eth1, as cloudlab/bin/config's config_qdisc does (mq at the root, homa on each
# child), or as the root qdisc when eth1 has a single queue (mq needs several). The homa
# qdisc takes no options, so stock tc can attach it. "show" prints the qdiscs and the
# speed eth1 reports (virtio-net: "Unknown!", i.e. SPEED_UNKNOWN; round-4 candidate 5).

{ pkgs }:

pkgs.writeShellApplication {
  name = "homa-qdisc";
  runtimeInputs = with pkgs; [ coreutils gnugrep iproute2 ethtool ];
  text = ''
    dev=eth1
    queues=$(find /sys/class/net/$dev/queues -maxdepth 1 -name 'tx-*' | wc -l)
    case "''${1:-show}" in
      on)
        if [ "$queues" -gt 1 ]; then
          tc qdisc replace dev $dev root handle 1: mq
          for i in $(seq "$queues"); do
            tc qdisc replace dev $dev parent "1:$(printf %x "$i")" homa
          done
        else
          tc qdisc replace dev $dev root homa
        fi
        ;;
      off)
        tc qdisc del dev $dev root 2> /dev/null || true
        ;;
      show) ;;
      *)
        echo "usage: homa-qdisc on|off|show" >&2
        exit 2
        ;;
    esac
    echo "tx queues $queues, $(ethtool $dev | grep -E 'Speed:' | sed 's/^[[:space:]]*//')"
    tc qdisc show dev $dev
  '';
}
