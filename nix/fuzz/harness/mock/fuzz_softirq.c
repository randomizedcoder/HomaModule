// SPDX-License-Identifier: BSD-2-Clause or GPL-2.0+
/*
 * fuzz_softirq.c - libFuzzer harness that feeds packets through Homa's real
 * receive path (homa_softirq -> homa_dispatch_pkts -> homa_*_pkt) on top of
 * the unit-test mock layer (test/mock.c, test/utils.c).
 *
 * Each input sets up a small amount of RPC state (mirroring the
 * homa_incoming unit-test fixture), then delivers up to MAX_PKTS packets
 * whose bytes come from the fuzzer. Afterwards everything is torn down and
 * the mock layer's leak checks (skbs, kmallocs, pages, locks, ...) are run;
 * any FAIL() from those checks, or from a sanitizer, aborts the run.
 *
 * Input format:
 *   byte 0   scenario (see setup_scenario)
 *   byte 1   flags: bit 0 = aim sport/dport/sender_id at the scenario's
 *            RPC; bit 1 = IPv4 instead of IPv6; bit 2 = with scenario 6,
 *            aim at the server RPC instead of the client RPC
 *   then     repeated [u16 little-endian length][length bytes] packets
 *
 * Build with -DPIN_TYPE=<opcode> to force every packet's type byte to a
 * single opcode, so that the fuzzer spends its time inside one handler.
 */

#define KSELFTEST_NOT_MAIN 1
#include "homa_impl.h"
#include "homa_grant.h"
#include "homa_qdisc.h"
#include "homa_rpc.h"
#include "homa_sock.h"
#include "homa_wire.h"
#include "kselftest_harness.h"
#include "ccutils.h"
#include "mock.h"
#include "utils.h"

#define MAX_PKTS 8

/* test/mock.c reports leaks and lock imbalances with FAIL(), which
 * clears __current_test->passed. main.c normally owns this storage.
 */
static struct __test_metadata fuzz_meta = {.name = "fuzz"};
struct __test_metadata *__current_test = &fuzz_meta;
struct __test_metadata *__test_list;
unsigned int __test_count;
unsigned int __fixture_count;
int __constructor_order;

struct fuzz_env {
	struct in6_addr client_ip;
	struct in6_addr server_ip;
	struct homa homa;
	struct homa_net *hnet;
	struct homa_sock hsk;
	struct homa_sock hsk2;

	/* Packets are aimed at this RPC when flags bit 0 is set. */
	struct in6_addr *saddr;
	struct in6_addr *daddr;
	u16 sport;
	u16 dport;
	u64 sender_id;
};

enum {
	CLIENT_PORT = 40000,
	SERVER_PORT = 99,
	CLIENT_ID = 1234,
	SERVER_ID = 1235,
};

static void aim_at_client(struct fuzz_env *env)
{
	env->saddr = &env->server_ip;
	env->daddr = &env->client_ip;
	env->sport = SERVER_PORT;
	env->dport = env->hsk.port;
	env->sender_id = SERVER_ID;
}

static void aim_at_server(struct fuzz_env *env)
{
	env->saddr = &env->client_ip;
	env->daddr = &env->server_ip;
	env->sport = CLIENT_PORT;
	env->dport = SERVER_PORT;
	env->sender_id = CLIENT_ID;
}

static void setup_scenario(struct fuzz_env *env, u8 scenario, u8 flags)
{
	aim_at_server(env);
	switch (scenario % 8) {
	case 0:
		/* No RPCs at all: exercises the unknown-RPC paths. */
		break;
	case 1:
		unit_client_rpc(&env->hsk, UNIT_OUTGOING, &env->client_ip,
				&env->server_ip, SERVER_PORT, CLIENT_ID, 2000,
				10000);
		aim_at_client(env);
		break;
	case 2:
		unit_client_rpc(&env->hsk, UNIT_RCVD_ONE_PKT, &env->client_ip,
				&env->server_ip, SERVER_PORT, CLIENT_ID, 2000,
				10000);
		aim_at_client(env);
		break;
	case 3:
		unit_server_rpc(&env->hsk2, UNIT_RCVD_ONE_PKT, &env->client_ip,
				&env->server_ip, CLIENT_PORT, SERVER_ID, 10000,
				100);
		break;
	case 4:
		unit_server_rpc(&env->hsk2, UNIT_IN_SERVICE, &env->client_ip,
				&env->server_ip, CLIENT_PORT, SERVER_ID, 10000,
				100);
		break;
	case 5:
		unit_server_rpc(&env->hsk2, UNIT_OUTGOING, &env->client_ip,
				&env->server_ip, CLIENT_PORT, SERVER_ID, 100,
				20000);
		break;
	case 6:
		unit_client_rpc(&env->hsk, UNIT_OUTGOING, &env->client_ip,
				&env->server_ip, SERVER_PORT, CLIENT_ID, 20000,
				1000);
		unit_server_rpc(&env->hsk2, UNIT_RCVD_ONE_PKT, &env->client_ip,
				&env->server_ip, CLIENT_PORT, SERVER_ID + 2,
				10000, 100);
		if (flags & 4)
			env->sender_id = CLIENT_ID + 2;
		else
			aim_at_client(env);
		break;
	case 7:
		unit_client_rpc(&env->hsk, UNIT_RCVD_MSG, &env->client_ip,
				&env->server_ip, SERVER_PORT, CLIENT_ID, 2000,
				1000);
		aim_at_client(env);
		break;
	}
}

static void deliver(struct fuzz_env *env, const u8 *data, size_t len,
		    u8 flags)
{
	struct homa_common_hdr *h;
	struct sk_buff *skb;

	skb = mock_skb_alloc(env->saddr, env->daddr, NULL, len, 0);
	h = skb_put(skb, len);
	memcpy(h, data, len);
	if (len >= sizeof(*h)) {
#ifdef PIN_TYPE
		h->type = PIN_TYPE;
#endif
		if (flags & 1) {
			h->sport = htons(env->sport);
			h->dport = htons(env->dport);
			h->sender_id = cpu_to_be64(env->sender_id);
		}
	}

	/* FREEZE is a debugging aid that freezes the timetrace; it isn't
	 * part of the protocol, so keep the fuzzer out of it.
	 */
	if (len > offsetof(struct homa_common_hdr, type) && h->type == FREEZE)
		h->type = DATA;
	homa_softirq(skb);
}

int LLVMFuzzerTestOneInput(const u8 *data, size_t size)
{
	static struct fuzz_env env;
	u8 scenario, flags;
	int npkts;

	if (size < 2)
		return 0;
	scenario = data[0];
	flags = data[1];
	data += 2;
	size -= 2;

	memset(&env, 0, sizeof(env));
	fuzz_meta.passed = 1;
	mock_ipv6_default = !(flags & 2);
	mock_ipv6 = mock_ipv6_default;
	env.client_ip = unit_get_in_addr("196.168.0.1");
	env.server_ip = unit_get_in_addr("1.2.3.4");
	homa_init(&env.homa);
	env.hnet = mock_hnet(0, &env.homa);
	env.homa.num_priorities = 1;
	env.homa.poll_cycles = 0;
	env.homa.qshared->fifo_fraction = 0;
	env.homa.unsched_bytes = 10000;
	env.homa.grant->window = 10000;
	mock_sock_init(&env.hsk, env.hnet, 0);
	mock_sock_init(&env.hsk2, env.hnet, SERVER_PORT);
	setup_scenario(&env, scenario, flags);
	unit_log_clear();

	for (npkts = 0; npkts < MAX_PKTS && size >= 2; npkts++) {
		size_t len = data[0] | (data[1] << 8);

		data += 2;
		size -= 2;
		if (len > size)
			len = size;
		if (len > 1500)
			len = 1500;
		deliver(&env, data, len, flags);
		data += len;
		size -= len;
	}

	homa_destroy(&env.homa);
	unit_teardown();
	if (!fuzz_meta.passed)
		abort();
	return 0;
}
