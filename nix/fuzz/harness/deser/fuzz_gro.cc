/* deser/fuzz_gro.cc — Focus A: the GRO receive path.
 *
 * homa_gro_receive() (homa_offload.c) casts skb_transport_header(skb) to homa_data_hdr and
 * does __skb_pull bounds work — a prime OOB/under-read target. This harness builds an skb
 * from fuzz bytes and drives it through homa_gro_receive() with an empty held list.
 *
 * Best-effort: the GRO path reads NAPI/offload state, so some inputs may exercise less than
 * the full path without a fuller offload fixture. Kernel-mock harness (test build env).
 */
#include "mock_harness.h"

extern "C" {
struct sk_buff *homa_gro_receive(struct list_head *held_list, struct sk_buff *skb);
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    homa_fuzz::Env *e = homa_fuzz::setup();

    struct homa_common_hdr common;
    memset(&common, 0, sizeof(common));
    common.sport = htons(40000);
    common.dport = htons(e->server_port);
    common.type = (size > offsetof(struct homa_common_hdr, type))
                  ? data[offsetof(struct homa_common_hdr, type)] : (uint8_t)DATA;

    int extra = (int)(size > sizeof(struct homa_data_hdr)
                      ? size - sizeof(struct homa_data_hdr) : 0);
    struct sk_buff *skb = mock_skb_alloc(&e->server_ip, &e->client_ip, &common, extra, 0);
    if (skb) {
        size_t n = size < (size_t)skb->len ? size : (size_t)skb->len;
        if (n) memcpy(skb->data, data, n);

        LIST_HEAD(held);
        struct sk_buff *ret = homa_gro_receive(&held, skb);
        /* homa_gro_receive returns NULL when it consumes/holds the skb; if it returns the
         * skb back to us unmerged, free it to avoid a leak across iterations. */
        if (ret == skb)
            kfree_skb(skb);
    }

    homa_fuzz::teardown(e);
    return 0;
}
