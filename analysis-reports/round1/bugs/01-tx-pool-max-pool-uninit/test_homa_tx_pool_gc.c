/* Bug 1 — merge into test/unit_homa_tx_pool.c; needs mock helpers
 * mock_tx_pool_alloc() and mock_bad_deref_count() (poisoned-pointer guard).
 */

FIXTURE(homa_tx_pool_gc) { struct homa homa; struct homa_sock hsk; };
FIXTURE_SETUP(homa_tx_pool_gc) { mock_homa_init(&self->homa); }
FIXTURE_TEARDOWN(homa_tx_pool_gc) { homa_destroy(&self->homa); }

struct gc_case { const char *name; int max_numa; int low_marks[4]; bool slot_null[4]; };

static const struct gc_case gc_cases[] = {
	{ "one pool low_mark 0",   0, {0},        {false} },
	{ "one pool low_mark -1",  0, {-1},       {false} },
	{ "all slots NULL",        2, {0,0,0},    {true,true,true} },
	{ "three pools pick max",  2, {1,5,2},    {false,false,false} },
};

TEST_F(homa_tx_pool_gc, no_uninitialized_pool_deref)
{
	for (size_t i = 0; i < ARRAY_SIZE(gc_cases); i++) {
		const struct gc_case *c = &gc_cases[i];

		self->homa.max_numa = c->max_numa;
		for (int n = 0; n <= c->max_numa; n++)
			self->homa.tx_pools[n] = c->slot_null[n] ? NULL :
				mock_tx_pool_alloc(&self->homa, c->low_marks[n]);
		self->homa.tx_page_free_time = 0;

		homa_tx_pool_gc(&self->homa);
		EXPECT_EQ(0, mock_bad_deref_count());
	}
}
