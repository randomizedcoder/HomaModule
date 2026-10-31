# nix/microvms/ports.nix
#
# Every host port the VM tests bind on 127.0.0.1, from one table, so that all of them can
# run at once (homa-vm-matrix). Evaluation fails if two tests would share a port.
#
#   console <name>   { serial; virtio; }: a lifecycle guest's consoles (TCP), two ports from
#                    lifecycle.portBase on
#   pairConsoles <name>
#                    { node0 = { serial; virtio; }; node1 = ...; }: a pair lifecycle's
#                    consoles (TCP), four ports from lifecycle.pairConsoleBase on
#   link <name>      a pair's eth1 link: one port from pair.linkPortBase on. A "dgram"
#                    link is UDP on link and link + pair.dgramPortOffset, a "socket" link
#                    TCP on link.
#
# <name> is "default" or a vmMatrix series for the consoles; for links, any name in
# linkNames. Ports are handed out in list order, so adding a kernel only appends ports.

{ lib, constants, vmSeries, linkNames }:

let
  lc = constants.lifecycle;
  pair = constants.pair;

  consoleNames = [ "default" ] ++ vmSeries;
  indexOf = names: lib.listToAttrs (lib.imap0 (i: n: lib.nameValuePair n i) names);
  consoleIndex = indexOf consoleNames;
  linkIndex = indexOf (map (l: l.name) linkNames);

  console = name:
    let base = lc.portBase + 2 * consoleIndex.${name}; in
    { serial = base; virtio = base + 1; };

  pairConsoles = name:
    let base = lc.pairConsoleBase + 4 * consoleIndex.${name}; in
    {
      node0 = { serial = base; virtio = base + 1; };
      node1 = { serial = base + 2; virtio = base + 3; };
    };

  link = name: pair.linkPortBase + linkIndex.${name};

  # Every port as "<proto>/<port>" with its owner: TCP and UDP ports are separate, so a UDP
  # link may share a number with a TCP console.
  bound =
    lib.concatMap
      (n: map (p: { key = "tcp/${toString p}"; owner = "console ${n}"; })
        (lib.attrValues (console n)
        ++ lib.concatMap lib.attrValues (lib.attrValues (pairConsoles n))))
      consoleNames
    ++ lib.concatMap
      (l:
        let p = link l.name; in
        if l.link == "dgram" then [
          { key = "udp/${toString p}"; owner = "link ${l.name}"; }
          { key = "udp/${toString (p + pair.dgramPortOffset)}"; owner = "link ${l.name}"; }
        ] else [
          { key = "tcp/${toString p}"; owner = "link ${l.name}"; }
        ])
      linkNames;

  clashes = lib.filterAttrs (_: owners: lib.length owners > 1)
    (lib.groupBy' (acc: b: acc ++ [ b.owner ]) [ ] (b: b.key) bound);
in
assert lib.assertMsg (clashes == { })
  "nix/microvms/ports.nix: ports bound twice: ${builtins.toJSON clashes}";
{
  inherit console pairConsoles link;
}
