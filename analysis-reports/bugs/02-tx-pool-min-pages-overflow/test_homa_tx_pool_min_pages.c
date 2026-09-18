/* Bug 2 — merge into test/unit_homa_tx_pool.c. Assumes the size math is
 * extracted into a pure helper: int homa_tx_pool_min_pages(struct homa *).
 */

FIXTURE(homa_tx_pool_min) { struct homa homa; };
FIXTURE_SETUP(homa_tx_pool_min) { mock_homa_init(&self->homa); }
FIXTURE_TEARDOWN(homa_tx_pool_min) { homa_destroy(&self->homa); }

struct minpg_case { const char *name; int min_kb; };

static const struct minpg_case minpg_cases[] = {
	{ "typical 1024kb", 1024    },
	{ "zero",           0       },
	{ "int-fit 2147kb", 2147    },
	{ "overflow 2.1GB", 2147484 },
	{ "int_max kb",     INT_MAX },
};

TEST_F(homa_tx_pool_min, min_pages_never_overflows)
{
	for (size_t i = 0; i < ARRAY_SIZE(minpg_cases); i++) {
		self->homa.tx_page_pool_min_kb = minpg_cases[i].min_kb;
		EXPECT_GE(homa_tx_pool_min_pages(&self->homa), 0);
	}
}
