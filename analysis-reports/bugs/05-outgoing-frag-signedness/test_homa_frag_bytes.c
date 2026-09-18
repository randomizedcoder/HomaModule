/* Bug 5 — merge into test/unit_homa_outgoing.c. Assumes the per-frag clamp is
 * extracted: int homa_frag_bytes(u32 frag_size, int skip, int left).
 */

struct frag_case { const char *name; u32 frag_size; int skip; int left; int expect; };

static const struct frag_case frag_cases[] = {
	{ "frag>left",   4096, 0,   100,  100 },
	{ "left>frag",   200,  0,   5000, 200 },
	{ "skip==size",  200,  200, 50,   0   },
	{ "skip>size",   200,  300, 50,   0   },
};

TEST(homa_frag_bytes_signedness)
{
	for (size_t i = 0; i < ARRAY_SIZE(frag_cases); i++) {
		const struct frag_case *c = &frag_cases[i];
		int got = homa_frag_bytes(c->frag_size, c->skip, c->left);

		EXPECT_GE(got, 0);
		EXPECT_EQ(c->expect, got);
	}
}
