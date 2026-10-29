# Round 4 — PR candidates (plan)

Base: upstream `main` @ `4bd0275` (2026-10-27). These come from reading the code by hand
for copy-paste asymmetries and error paths, plus a sparse/W=1 re-run. They are not tool
findings: rounds 1–3 used up most of what the tools report.

The rules are those in [`../pr-tracker.md`](../pr-tracker.md#what-the-maintainer-wants-from-reviewing-all-three-rounds):
- one bug per branch;
- a `TEST_F` test only when behaviour changes, placed in the function's group, red before
  the fix and green after;
- each branch must strip cleanly (`make __STRIP__=1`);
- no nix files.

In-flight upstream work to avoid duplicating: #133 (CI), #134 (strip.py), #135
(`homa_rpc_alloc_server` `waiting_for_bufs`), #136 (`homa_sock_destroy` shutdown).

**Status (2026-10-28):** 1–4 are fork drafts #18–#21. Each was done test-first: the
new test failed on `main`, then passed with the fix. The full unit suite is 885/885 in
both IPv6 and `--ipv4` modes, `homa.ko` compiles with and without `__STRIP__` on 7.3,
and checkpatch is clean.

## Batch (8)

| # | Branch (proposed) | Where | Bug | Reach | Test | Confidence |
|---|---|---|---|---|---|---|
| 1 | `fix/qdisc-bypass-ipv6-hash` (fork #18) | `homa_qdisc.c` `homa_qdisc_can_bypass` | The IPv6 daddr hash for `skb` XORs words `[0]^[2]^[3]`; the loop over deferred packets uses `[0]^[1]^[2]^[3]`. For any address with a non-zero word 1 they never match, so a TCP packet bypasses deferred packets of the **same flow** and gets reordered. The existing test uses IPv4-mapped addresses (word 1 = 0), which hides it | any IPv6 TCP traffic through the Homa qdisc | yes: `homa_qdisc_can_bypass__ipv6_address_uses_all_words` (real v6 address) | high (verified) |
| 2 | `fix/hijack-gro-ipv6-tcp` (fork #19) | `homa_hijack.c` `homa_hijack_gro_receive` | Non-hijacked packets always go to `tcp_net_offload` (IPv4) `gro_receive`, even when they arrived through `hook_tcp6_net_offload`. `tcp6_net_offload` is saved but never used. IPv6 TCP packets go through `tcp4_gro_receive`, which reads the v6 header as an `iphdr` (pseudo-header checksum, fraglist lookup) | every IPv6 TCP packet once homa is loaded (`homa_hijack_init` runs at load) | yes: an IPv6 pass-through test expecting `unit_tcp6_gro_receive` (the fixture already installs it) | high (verified) |
| 3 | `fix/rpc-get-info-private-flag` (fork #20) | `homa_rpc.c` `homa_rpc_get_info` | `rpc->flags & RPC_PRIVATE`, but `RPC_PRIVATE` is a **bit number** (2), so this tests bit 1, `APP_NEEDS_LOCK`. HOMAIOCINFO misreports `HOMA_RPC_PRIVATE`. The existing test sets `flags \|= RPC_PRIVATE`, which hides it | any HOMAIOCINFO caller | fix the existing test to `set_bit(RPC_PRIVATE, ...)` (red before the fix) | high (verified) |
| 4 | `fix/qdisc-destroy-next-qdisc` (fork #21) | `homa_qdisc.c` `homa_qdisc_destroy` | `list_del_init(&q->defer_links)` leaves the round-robin cursor `qdev->next_qdisc` able to point at `q`, and the pacer then does `list_entry(next_qdisc)` on the freed qdisc. **Use-after-free.** Fix: advance the cursor before the unlink, under the qdev lock already held | `tc qdisc replace` or delete of one queue while TCP is deferred on others | yes: defer on q1/q2/q3, cursor at q2, destroy q2, the pacer sends from q3 | high (verified) |
| 5 | `fix/qdisc-unknown-link-speed` | `homa_qdisc.c` `homa_qdev_update_sysctl` | `get_link_ksettings` succeeds with `speed = SPEED_UNKNOWN` (-1), as on virtio-net or a link that is down. Then `link_mbps = -1`, `max_nic_queue_bytes < 0`, and everything is deferred and never sent. Speed 0 gives `do_div(tmp, 0)`. Fix: keep `homa->link_mbps` unless the speed is valid | Homa qdisc on virtio or a link that is down | yes: copy `__cant_get_link_speed_from_dev` with `mock_link_mbps = SPEED_UNKNOWN` | high |
| 6 | `fix/qdisc-destroy-after-init-failure` | `homa_qdisc.c` `homa_qdisc_destroy` | The kernel calls `ops->destroy` even when `ops->init` fails (`qdisc_create`). If `homa_qdisc_qdev_get` failed, `q->qdev` is NULL and destroy oopses. Fix: `if (!q->qdev) return;` | an allocation or kthread failure while attaching the qdisc | yes: extend `homa_qdisc_init__cant_create_new_qdisc_dev` | high correctness, low impact |
| 7 | `fix/softirq-cores-bounds` | `homa_plumbing.c` `homa_sysctl_softirq_cores`, `homa_offload.c` `homa_offload_init` | The sysctl checks `core >= nr_cpu_ids` but not negatives. The default `gen3_softirq_cores[0] = i ^ 1` equals `nr_cpu_ids` on the last CPU when the CPU count is odd. Both reach `per_cpu(homa_offload_core, core)` out of bounds under GEN3 | root sysctl; GEN3 gro_policy on an odd CPU count | yes for the sysctl rejection | high bug; needs root or non-default policy |
| 8 | `fix/tx-priority-mapped-twice` | `homa_outgoing.c` `homa_tx_skb_send` | DATA applies `priority_map[]`, then `homa_route_xmit` applies it again, so a non-identity map sends the wrong priority (and an entry ≥ 8 indexes past the map). Control packets map once | custom `priority_map` sysctl | yes: non-identity map, check the logged priority | medium-high, **re-verify** |

Suggested order: 1–4 first (verified, clear impact), then 5–8. Every test is a single
`TEST_F` of 10–25 lines in `test/unit_<same file>.c`.

## Hold / ask first

- **6.18-stable build** (6.18.40 recvmsg, 6.18.57 bind backports): `< KERNEL_VERSION(7, x, 0)`
  gates pick old signatures on 6.18.57. John plans to move `main` to the next LTS. Ask on
  #120 or an issue which LTS he means before sending gate changes.
- **`homa_err_handler_v4` treats `ICMP_FRAG_NEEDED` as unreachable** and aborts RPCs (the v6
  handler ignores PKT_TOOBIG); its `pr_notice` for other ICMP types is not rate-limited.
  This is a policy call, so better as a question than a PR.
- **`homa_softirq` verbose `pr_warn`** reads `h->type` before `h` is set for this skb.
  Debug-only (verbose sysctl), no test. Could ride along as a one-liner.

## Dropped

| Item | Why |
|---|---|
| Dead counters `total_rpcs`, `element`, `num_updates`, `recovered` (gcc W=1) | Style only; John may use them while debugging |
| sparse `context imbalance` (~50) | Annotation churn, by design (functions return locked) |
| sparse shadows (`skb_frag`, `nid`, `__ret`) | Benign; each name is used in its own scope |
| `homa_peer.c` no newline at EOF | Trivial; #133's checkpatch CI will catch it |
| `homa_pool.c` `__user` casts | Only `__force` silences them (round 3) |
| `max_sched_prio` no upper clamp | Root misconfiguration only |
