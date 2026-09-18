/* Bug 6 — merge into test/unit_homa_tx_pool.c. mock_pool_copy_at() drives the
 * kmap+copy_from_iter path; mock_page_region_is() checks the destination bytes.
 */

struct kmap_case { const char *name; int p_off; int p_len; };

static const struct kmap_case kmap_cases[] = {
	{ "mid-page",  64,   128 },
	{ "zero-off",  0,    256 },
	{ "last-byte", 4095, 1   },
	{ "zero-len",  100,  0   },
};

TEST(homa_pool_copy_offsets)
{
	for (size_t i = 0; i < ARRAY_SIZE(kmap_cases); i++) {
		const struct kmap_case *c = &kmap_cases[i];

		mock_iter_fill(0xAB, c->p_len);
		EXPECT_EQ(c->p_len, mock_pool_copy_at(c->p_off, c->p_len));
		EXPECT_TRUE(mock_page_region_is(0xAB, c->p_off, c->p_len));
	}
}
