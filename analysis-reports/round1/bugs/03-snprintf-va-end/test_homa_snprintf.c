/* Bug 3 — merge into test/unit_homa_devel.c. mock_va_list_leaks() reports
 * va_start calls not matched by va_end (wire it in the mock/UBSan shim).
 */

struct snp_case { const char *name; int size; int used; const char *fmt; int arg;
		  const char *sarg; int expect; };

static const struct snp_case snp_cases[] = {
	{ "normal",     64, 0, "x=%d", 5, NULL,          3 },
	{ "full",        4, 3, "%d",   9, NULL,          3 },
	{ "past-end",    4, 10,"%d",   9, NULL,         10 },
	{ "truncate",    8, 0, "%s",   0, "abcdefghij",  7 },
};

TEST(homa_snprintf_all_paths_va_end)
{
	char buf[64];

	for (size_t i = 0; i < ARRAY_SIZE(snp_cases); i++) {
		const struct snp_case *c = &snp_cases[i];
		int r = c->sarg ? homa_snprintf(buf, c->size, c->used, c->fmt, c->sarg)
				: homa_snprintf(buf, c->size, c->used, c->fmt, c->arg);
		EXPECT_EQ(c->expect, r);
	}
	EXPECT_EQ(0, mock_va_list_leaks());
}
