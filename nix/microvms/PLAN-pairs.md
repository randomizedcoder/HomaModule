# Plan: Homa between pairs of microVMs

Goal: show that the flake can build Homa for several kernels, boot each kernel, and pass
real Homa traffic between two VMs, including across different kernel versions, with a
single `nix run` command. It doubles as a demo of the flake.

## Already in place

| Need | Target | Notes |
|---|---|---|
| Compile against several kernels | `homa-module-<series>`, `homa-build-matrix` | nixpkgs 6.1/6.6/6.12/6.18/latest plus kernel.org 7.0–7.2 trees (compile only) |
| One VM per kernel | `homa-microvm[-<series>]` | interactive, root autologin |
| Automated single-VM test | `homa-microvm-test[-<series>]`, `-debug` | insmod, loopback echo, netns/veth with GRO+RPS, rmmod; PASS/FAIL from the console |

Gaps:
- No VM-to-VM traffic: the netns/veth test stays inside one kernel.
- No single command that runs every kernel and prints a table.
- VM tests are generated for 6.1/6.6/6.18, where the module doesn't build (below the supported
  range; 6.18.57 has the stable backports), so they fail for reasons that aren't news.

## Design: the uds-rdma-proxy pair pattern

Two guests built by the existing `mkVm.nix`, each with a second NIC:

```
 node0 (server, kernel A)              node1 (client, kernel B)
 eth0  user NAT (store/init)           eth0  user NAT
 eth1  10.88.0.1/24  ◄── QEMU -netdev dgram ──►  eth1 10.88.0.2/24
       udp 127.0.0.1:<port>                   udp 127.0.0.1:<port>+1000
```

- `-netdev dgram` (UDP between two localhost ports): a private L2 link between the two qemu
  processes. No root, tap or bridge needed, so it works on any host with KVM, and in CI. The
  first version used `-netdev socket,listen|connect` (a TCP stream); that stalls some packets
  for milliseconds (STATUS.md F2) and is kept only as `homa-pair-exp-socket`.
- The port is derived from the pair name so different pairs can run in parallel.
- Hostnames are `node0`/`node1` with `/etc/hosts` entries, because `cp_node` addresses servers
  as `node<N>`.
- The server guest's oneshot: insmod, start `demo_server1` and `cp_node server`, print
  `HOMA_PAIR_SERVER_READY`, then idle.
- The client guest's oneshot runs phases. Each prints `HOMA_PAIR_<phase>_OK`, and the run ends
  with `HOMA_PAIR_PASS` or `HOMA_PAIR_FAIL:<phase>`:
  1. `ping` over eth1, so a broken link isn't reported as a Homa failure;
  2. echo 100 B–1 MB across VMs (`demo_client1 10.88.0.1`), which covers multi-packet messages
     and grants on a real NIC (virtio-net);
  3. a short `cp_node client --protocol homa` run (workload `w4`, a few seconds), checking that
     RPCs complete and the log shows no `incomplete` warnings;
  4. the same with `--protocol tcp`, giving a baseline to print beside the Homa numbers;
  5. rmmod and a dmesg gate (`BUG|Oops|WARNING.*homa`).
- Orchestrator (`lib-pair.nix`, xtcp2/uds-rdma-proxy style):
  1. start node0 and wait for READY;
  2. start node1 and wait for PASS or FAIL;
  3. power off node0, then apply the same dmesg gate to node0's console (catches oopses on the
     receive side);
  4. print one verdict, with both console logs kept in `$HOMA_VM_LOGDIR`.

## Phases

| # | Deliverable | New targets | Done when |
|---|---|---|---|
| 1 ✅ | Pair harness, same kernel | `homa-pair-test` (default kernel) | **Done:** echo + cp_node Homa/TCP pass on 7.3 ↔ 7.3, about 35 s cached; a client with a dead link fails at `PING`. The interactive pair (`homa-pair`) moves to phase 3 |
| 2 ✅ | Cross-kernel pairs | `homa-pair-test-<A>-<B>` for supported kernels (6.12 ↔ 7.3 both ways) | **Done:** all four pairings pass; each has its own link port, and all four run in parallel in 50 s. `vmSeries` in `kernel.nix` limits VM targets to 6.12 and 7.3 |
| 3 ✅ | One command for everything | `homa-vm-matrix` (`matrix.nix`): every single-VM test plus every pair, run in parallel, printing a table (kernel(s), verdict, echo, GRO calls, cp_node rates) | **Done:** 6 tests in 46 s. Its first run found a use-after-free in `homa_route_free` (STATUS.md F8); guests now boot with `init_on_free=1` |
| 4 | Lossy and slow links | `homa-pair-test-netem`: `tc netem loss 1% delay 1ms` on eth1 | Echo still completes, and the RESEND/retransmit counters in `/proc/net/homa_metrics` move |
| 5 | Homa qdisc on virtio | the pair with `tc qdisc replace dev eth1 root homa` | Exercises the pacer across VMs. virtio-net reports `SPEED_UNKNOWN`, so this should reproduce round-4 candidate 5 (link speed −1): a red test in a VM, then green with the fix |
| 6 (stretch) | Boot 7.0–7.2 | full kernels built from the kernel-src.nix tarballs (`buildLinux`, about 30 min each, cached) | The VM matrix covers every 7.x series, not just compile-only |

Housekeeping, done with phase 1:
- Add a `vmSupported` list in `kernel.nix` (today 6.12 and 7.3), so VM and pair targets are
  generated only for kernels where the module builds.
- `homa-build-matrix` still reports all kernels, so the 6.1/6.6/6.18 failures stay visible
  there.

## Files

- `nix/microvms/constants.nix`: pair addresses, MACs, base port, server and client ready
  timeouts.
- `nix/microvms/mkVm.nix`: optional `pair = { role, ip, port }` argument adding eth1 (qemu
  `extraArgs`), static IP and hosts; `test` selects which in-guest script runs (smoke, pair
  server, pair client).
- `nix/microvms/pair.nix` (new): server and client in-guest scripts, shellcheck-clean, using
  the same phase-marker style as `smoke.nix`.
- `nix/microvms/lib-pair.nix` (new): two-VM orchestrator.
- `nix/microvms/matrix.nix` (new): parallel runner and summary table.
- `nix/microvms/default.nix`: wires up the new targets.
- `nix/README.md`, `DESIGN.md`: a demo section.

## Observations

- On the original `socket` link, Homa's cp_node P50 RTT was about 5 ms against about 0.3 ms
  for TCP. The latency sweep (`homa-pair-exp`) traced it to the link: QEMU's TCP stream
  backend delays packets, and Homa recovers through its 5 × 1 ms RESEND timer. Over `dgram`
  the two protocols match. See [`../STATUS.md`](../STATUS.md) F2.

## Caveats

- The emulated link is slow (a few hundred Mb/s to a few Gb/s), and the guests share host CPUs. cp_node numbers
  show that traffic flows, not how Homa performs; the demo output says so.
- Everything stays on the fork's `nix-flake` branch. Nothing goes upstream. The only upstream
  benefit is bugs it finds, for example phase 5.
- Resources: two guests of 2 vCPU and 2 GiB each; the full matrix at about 5 pairs needs
  about 20 GiB, which this host (24 cores, 125 GiB) handles.
