/* Bug 7 — merge into test/unit_homa_incoming.c. mock_data_skb() builds a DATA
 * packet with the given wire seg.offset (mirrors nix/fuzz/harness/deser).
 */

FIXTURE(homa_data_deser) { struct homa homa; struct homa_sock hsk; struct homa_rpc *rpc; };
FIXTURE_SETUP(homa_data_deser)
{
	mock_homa_init(&self->homa);
	self->rpc = mock_incoming_rpc(&self->homa, &self->hsk, /*len=*/10000);
}
FIXTURE_TEARDOWN(homa_data_deser) { homa_destroy(&self->homa); }

struct off_case { const char *name; u32 wire_offset; bool expect_accept; };

static const struct off_case data_off_cases[] = {
	{ "zero",       0,          true  },
	{ "mid",        5000,       true  },
	{ "last-valid", 9999,       true  },
	{ "at-len",     10000,      false },
	{ "high-bit",   0x80000000, false },
	{ "max-u32",    0xFFFFFFFF, false },
};

TEST_F(homa_data_deser, offset_out_of_range_rejected)
{
	for (size_t i = 0; i < ARRAY_SIZE(data_off_cases); i++) {
		const struct off_case *c = &data_off_cases[i];
		struct sk_buff *skb = mock_data_skb(self->rpc, 10000, c->wire_offset);

		unit_log_clear();
		homa_data_pkt(skb, self->rpc);
		EXPECT_EQ(c->expect_accept, !unit_log_contains("dropped"));
	}
}
