/* nix/fuzz/harness/mock_harness.h
 *
 * Shared scaffolding for the kernel-mock libFuzzer harnesses (Focus A/B). It reuses Homa's
 * existing user-space mock layer (test/mock.c) — the same one the unit tests use — to build
 * an sk_buff from fuzz bytes and drive it through the real deserialization code in
 * homa_incoming.c. Compiled in the test/ build environment (kernel headers + -D__UNIT_TEST__),
 * so these targets are kernel-header dependent (see docs/DESIGN.md §5,§7).
 *
 * setup()/teardown() mirror FIXTURE_SETUP/FIXTURE_TEARDOWN(homa_incoming): homa_init +
 * mock_hnet + mock_sock_init(server_port), then homa_destroy + unit_teardown. dispatch_bytes()
 * builds a packet of the given type whose dport matches the bound socket (so the packet
 * reaches the per-type parsers), overlays the fuzz bytes onto the header region, and calls
 * homa_dispatch_pkts().
 */
#ifndef HOMA_MOCK_HARNESS_H
#define HOMA_MOCK_HARNESS_H

extern "C" {
#include "homa_impl.h"
#include "homa_interest.h"
#include "homa_peer.h"
#include "homa_pool.h"
#include "homa_wire.h"
#include "mock.h"
#include "utils.h"

void homa_dispatch_pkts(struct sk_buff *skb);
}

#include <cstdint>
#include <cstring>

namespace homa_fuzz {

struct Env {
    struct homa homa;
    struct homa_net *hnet;
    struct homa_sock hsk;
    struct in6_addr client_ip;
    struct in6_addr server_ip;
    int server_port;
};

/* Per-iteration setup, mirroring the homa_incoming fixture. */
inline Env *setup() {
    static Env e;
    memset(&e, 0, sizeof(e));
    e.server_port = 99;
    e.client_ip = unit_get_in_addr("196.168.0.1");
    e.server_ip = unit_get_in_addr("1.2.3.4");
    homa_init(&e.homa);
    e.hnet = mock_hnet(0, &e.homa);
    mock_sock_init(&e.hsk, e.hnet, e.server_port);
    return &e;
}

inline void teardown(Env *e) {
    homa_destroy(&e->homa);
    unit_teardown();
}

/* Build a packet of `type` addressed to the bound socket, overlay `data`/`size` onto the
 * header bytes, and dispatch it. `type` == 0 means "take the type byte from the fuzz input"
 * (whole-packet entry); otherwise the type is pinned (per-type harness). */
inline void dispatch_bytes(uint8_t type, const uint8_t *data, size_t size) {
    Env *e = setup();

    struct homa_common_hdr common;
    memset(&common, 0, sizeof(common));
    common.sport = htons(40000);
    common.dport = htons(e->server_port);
    common.type = type ? type
                       : (size > offsetof(struct homa_common_hdr, type)
                          ? data[offsetof(struct homa_common_hdr, type)]
                          : (uint8_t)DATA);
    common.sender_id = cpu_to_be64(1234);

    /* Allocate an skb with this header plus enough tail room to hold all the fuzz bytes. */
    int extra = (int)(size > sizeof(struct homa_data_hdr)
                      ? size - sizeof(struct homa_data_hdr) : 0);
    struct sk_buff *skb = mock_skb_alloc(&e->server_ip, &e->client_ip,
                                         &common, extra, 0);
    if (skb) {
        /* Overlay the fuzz bytes onto the header region, but keep dport intact so the
         * packet is routed to the bound socket and reaches the deep parsers. */
        size_t n = size;
        if (n > (size_t)skb->len)
            n = (size_t)skb->len;
        if (n > 0)
            memcpy(skb->data, data, n);
        struct homa_common_hdr *h = (struct homa_common_hdr *)skb->data;
        h->dport = htons(e->server_port);
        if (type)
            h->type = type;

        homa_dispatch_pkts(skb);
    }

    teardown(e);
}

} // namespace homa_fuzz

#endif /* HOMA_MOCK_HARNESS_H */
