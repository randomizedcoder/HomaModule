/* Bug 4 — merge into test/unit_homa_timer.c. Drives the per-RPC timer check
 * and asserts on the NEED_ACK emission via the unit log.
 */

FIXTURE(homa_timer) { struct homa homa; struct homa_sock hsk; struct homa_rpc rpc; };
FIXTURE_SETUP(homa_timer) { mock_homa_init(&self->homa); }
FIXTURE_TEARDOWN(homa_timer) { homa_destroy(&self->homa); }

struct ackwin_case { const char *name; u32 done; u32 ack; u32 now; bool expect_ack; };

static const struct ackwin_case ackwin_cases[] = {
	{ "elapsed",       100,        10, 120, true  },
	{ "not-yet",       100,        10, 105, false },
	{ "at-threshold",  100,        10, 109, false },
	{ "one-past",      100,        10, 110, true  },
	{ "wrapped",       0xFFFFFFF0, 10, 5,   true  },
};

TEST_F(homa_timer, need_ack_window_wraps_safely)
{
	for (size_t i = 0; i < ARRAY_SIZE(ackwin_cases); i++) {
		const struct ackwin_case *c = &ackwin_cases[i];

		mock_setup_outgoing_rpc(&self->rpc, c->done);
		self->homa.request_ack_ticks = c->ack;
		self->homa.timer_ticks = c->now;
		unit_log_clear();
		homa_timer_check_rpc(&self->rpc);
		EXPECT_EQ(c->expect_ack, unit_log_contains("Sent NEED_ACK"));
	}
}
