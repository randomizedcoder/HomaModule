/* Bug 8 — merge into test/unit_homa_incoming.c. Reuses the homa_data_deser
 * fixture; mock_grant_skb() builds a GRANT packet with the given wire offset.
 */

struct grant_case { const char *name; u32 wire_off; int granted0; int len; int expect; };

static const struct grant_case grant_cases[] = {
	{ "advance",   5000,       1000, 10000, 5000  },
	{ "stale",     500,        1000, 10000, 1000  },
	{ "at-len",    10000,      0,    10000, 10000 },
	{ "over-len",  12000,      0,    10000, 10000 },
	{ "high-bit",  0x80000000, 0,    10000, 10000 },
};

TEST_F(homa_data_deser, grant_offset_unsigned_and_clamped)
{
	for (size_t i = 0; i < ARRAY_SIZE(grant_cases); i++) {
		const struct grant_case *c = &grant_cases[i];

		self->rpc->state = RPC_OUTGOING;
		self->rpc->msgout.granted = c->granted0;
		self->rpc->msgout.length = c->len;
		homa_grant_pkt(mock_grant_skb(self->rpc, c->wire_off), self->rpc);
		EXPECT_EQ(c->expect, self->rpc->msgout.granted);
	}
}
