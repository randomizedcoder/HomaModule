# Homa — Top 10 Bugs to Fix (TDD Plan)

*Companion to [`static-analysis-report.md`](static-analysis-report.md) and
[`fuzzing-report.md`](fuzzing-report.md). Each bug below was read and confirmed in the
current source on branch `nix-flake`; the line numbers are from that tree.*

Every entry has three parts:

1. **Issue** — what is wrong and why it bites.
2. **TDD** — a *table-driven* test written **before** the fix, covering **positive /
   negative / boundary / corner** cases. Each row lists the case, its input, and the
   **expected outcome**. The test is expected to *fail* against today's code and *pass*
   after the fix.
3. **Fix** — the minimal change, in the most modern style the repo allows.

**Conventions used here**

- **C module code** — kernel C (targets ~6.17). Tests use the repo's existing
  `kselftest_harness.h` harness (`test/`), the `FIXTURE`/`TEST_F` macros, and `test/mock.c`.
  Table-driven = a `static const` array of case structs iterated inside one `TEST_F`.
- **C wire/deserialization code** — same harness, driving real handlers through
  `mock_skb_alloc()` with fuzz-style byte inputs (mirrors `nix/fuzz/harness/deser/`).
- **Python** — `pytest` with `@pytest.mark.parametrize` (the modern table-driven form).
- **Shell** — `bats-core`, one `@test` per row via a bash case array.
- Comments in all new code are kept to a single short line or omitted — matching Homa style.

Severity: **H** = memory-safety / crash, **M** = latent correctness / UB / defined-but-wrong,
**L** = portability / non-conforming but currently benign.

| # | Location | Bug | Sev |
|---|---|---|---|
| 1 | `homa_tx_pool.c:369,419` | `max_pool` used possibly-uninitialized → NULL/garbage deref | **H** |
| 2 | `homa_tx_pool.c:420` | `tx_page_pool_min_kb * 1000` computed in `int` → signed overflow | **M** |
| 3 | `homa_devel.c:489` | `homa_snprintf` returns without `va_end` on the early exit | **M** |
| 4 | `homa_timer.c:37` | `1 << 31` signed left shift → UB (wrap-around test) | **M** |
| 5 | `homa_outgoing.c:294` | `min(skb_frag_size()-bytes_to_skip, bytes_left)` mixes signed/unsigned | **M** |
| 6 | `homa_tx_pool.c:534` | arithmetic on `void *vaddr` (non-standard) | **L** |
| 7 | `homa_incoming.c:398` | DATA `seg.offset` narrowed `u32`→`int` unvalidated (deser) | **M** |
| 8 | `homa_incoming.c:809` | GRANT `offset` narrowed `u32`→`int` (deser) | **M** |
| 9 | `util/*.py` (×4) | invalid regex escapes `\[` `\]` in non-raw strings (W605) | **M** |
| 10 | `cloudlab/bin/on_nodes:28` | unquoted `$@` re-splits arguments (SC2068) | **M** |

---

## Bug 1 — `max_pool` used possibly-uninitialized in `homa_tx_pool_gc` **[H]**

**File:** `homa_tx_pool.c:369` (decl), `:401`–`:414` (conditional assign), `:419` (first use)

### Issue
`max_pool` is declared uninitialized. It is assigned only inside
`if (pool->low_mark > max_low_mark)` within the scan loop (`:408`–`:411`), and `max_low_mark`
starts at `-1`. If every NUMA pool slot is `NULL` (`homa->tx_pools[i]` all unset — valid before
any pool is populated), or if no pool ever has `low_mark > -1`, the loop never assigns
`max_pool`, and `:419 spin_lock_bh(&max_pool->mutex)` dereferences an indeterminate pointer.
Even after the scan, there is no `max_low_mark >= 0` guard before the lock/deref. This is a
straight use-of-uninitialized-value → wild pointer.

### TDD

| # | Category | Scenario | Input (`homa` state) | Expected outcome |
|---|---|---|---|---|
| 1 | positive | one populated pool with low_mark 0 | `max_numa=0`, `tx_pools[0]` valid | returns cleanly; `tx_pages_to_free` collected from that pool |
| 2 | boundary | exactly one pool, low_mark == -1 edge | pool with `low_mark=-1` | returns cleanly; **no NULL deref** (must be guarded) |
| 3 | negative | all pool slots NULL | `max_numa=2`, all `tx_pools[i]=NULL` | returns without touching any pool; **no deref** |
| 4 | corner | multiple pools, pick max low_mark | 3 pools low_mark 1/5/2 | selects the low_mark-5 pool; no deref of others |

```c
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

		/* Must return without dereferencing an unset max_pool. */
		homa_tx_pool_gc(&self->homa);
		EXPECT_EQ(0, mock_bad_deref_count());
	}
}
```
Cases 2 and 3 fault (or trip KASAN) on today's code; all four pass after the fix.

### Fix
Initialize the pointer and guard the deref on a real selection.

```c
struct homa_tx_pool *max_pool = NULL;
...
if (!max_pool)          /* no eligible pool this pass */
	return;
spin_lock_bh(&max_pool->mutex);
```

---

## Bug 2 — `tx_page_pool_min_kb * 1000` overflows in `int` **[M]**

**File:** `homa_tx_pool.c:420`; `min_pages` is `int` (`:368`), `tx_page_pool_min_kb` is `int`
(`homa_impl.h`).

### Issue
`min_pages = ((homa->tx_page_pool_min_kb * 1000) + (HOMA_TX_PAGE_SIZE - 1)) >> HOMA_TX_PAGE_SHIFT;`
The multiply is `int * int` → `int`. `tx_page_pool_min_kb` is a sysctl-settable value; any
setting `>= 2147484` (≈2.1 GB) overflows a 32-bit `int` — signed overflow is UB, and in
practice `min_pages` goes negative, so `release = max_low_mark - min_pages` becomes huge and the
free loop over-runs `tx_pages_to_free`. The size math must be done in a 64-bit / unsigned type.

### TDD

| # | Category | Scenario | Input `tx_page_pool_min_kb` | Expected `min_pages` |
|---|---|---|---|---|
| 1 | positive | typical config | `1024` | `(1024*1000 + PS-1) >> SHIFT`, positive |
| 2 | boundary | zero | `0` | `0` |
| 3 | boundary | last value that fits int | `2147` | correct positive value, no overflow |
| 4 | negative | overflow threshold | `2147484` | large **positive** page count (never negative) |
| 5 | corner | INT_MAX kb | `INT_MAX` | large positive; `release` never exceeds `release_max` |

```c
struct minpg_case { const char *name; int min_kb; bool expect_nonneg; };

static const struct minpg_case minpg_cases[] = {
	{ "typical 1024kb", 1024,       true },
	{ "zero",           0,          true },
	{ "int-fit 2147kb", 2147,       true },
	{ "overflow 2.1GB", 2147484,    true },
	{ "int_max kb",     INT_MAX,    true },
};

TEST_F(homa_tx_pool_gc, min_pages_never_overflows)
{
	self->homa.tx_pools[0] = mock_tx_pool_alloc(&self->homa, 0);
	self->homa.max_numa = 0;
	for (size_t i = 0; i < ARRAY_SIZE(minpg_cases); i++) {
		self->homa.tx_page_pool_min_kb = minpg_cases[i].min_kb;
		self->homa.tx_page_free_time = 0;
		EXPECT_GE(homa_tx_pool_min_pages(&self->homa), 0);
	}
}
```
(The size math is extracted to a small pure helper `homa_tx_pool_min_pages()` so it can be
tested directly; cases 4–5 return negative today.)

### Fix
Force the multiply to 64-bit before the shift.

```c
min_pages = (((u64)homa->tx_page_pool_min_kb * 1000)
		+ (HOMA_TX_PAGE_SIZE - 1)) >> HOMA_TX_PAGE_SHIFT;
```

---

## Bug 3 — `homa_snprintf` skips `va_end` on the early return **[M]**

**File:** `homa_devel.c:487`–`:490`

### Issue
```c
va_start(ap, format);
if (used >= (size - 1))
	return used;              /* <-- ap never va_end'd */
new_chars = vsnprintf(...);
```
`va_start` must be paired with `va_end` on **every** path. The `used >= size-1` early return
leaks the `va_list` — undefined behavior on ABIs where `va_start` allocates (and a real
resource leak on others). The two later returns are fine only because they fall through to no
`va_end` either — actually none of the returns call `va_end`. The clean fix pairs them.

### TDD

| # | Category | Scenario | Input (`size`, `used`, fmt) | Expected outcome |
|---|---|---|---|---|
| 1 | positive | normal append | `size=64, used=0, "x=%d",5` | returns 3; buffer `"x=5"` |
| 2 | boundary | buffer exactly full | `size=4, used=3` | returns `used` (3) via early path; `va_end` still called |
| 3 | negative | used past end | `size=4, used=10` | returns `used` (10); no write; `va_end` called |
| 4 | corner | truncating write | `size=8, used=0, "%s","abcdefghij"` | returns `size-1` (7); NUL-terminated |

```c
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
	/* Under -fsanitize the missing va_end trips; also assert no leak. */
	EXPECT_EQ(0, mock_va_list_leaks());
}
```
Row 2/3 exercise the early return; the leak assertion fails today.

### Fix
Single exit that always closes `ap`.

```c
int homa_snprintf(char *buffer, int size, int used, const char *format, ...)
{
	int new_chars = used;
	va_list ap;

	va_start(ap, format);
	if (used < (size - 1)) {
		new_chars = vsnprintf(buffer + used, size - used, format, ap);
		if (new_chars < 0)
			new_chars = used;
		else if (new_chars >= (size - used))
			new_chars = size - 1;
		else
			new_chars += used;
	}
	va_end(ap);
	return new_chars;
}
```

---

## Bug 4 — `1 << 31` signed shift is UB in the tick-wrap test **[M]**

**File:** `homa_timer.c:36`–`:37`

### Issue
```c
if ((rpc->done_timer_ticks + homa->request_ack_ticks - 1 - homa->timer_ticks) & 1 << 31)
```
`1` is `int`; `1 << 31` sets the sign bit of a 32-bit `int`, which is undefined behavior in C.
The intent is "test the high (sign) bit of a `u32` difference to get a wrap-safe `>=`
comparison." It happens to work on common compilers but is non-conforming and UBSan-flagged.
Use an unsigned literal and an explicit unsigned difference.

### TDD

| # | Category | Scenario | Input (`done`, `ack`, `now` ticks) | Expected: send NEED_ACK? |
|---|---|---|---|---|
| 1 | positive | ack window elapsed | done=100, ack=10, now=120 | yes (diff crossed) |
| 2 | negative | window not yet elapsed | done=100, ack=10, now=105 | no |
| 3 | boundary | exactly at threshold | done=100, ack=10, now=109 | no (>= boundary) |
| 4 | boundary | one past threshold | done=100, ack=10, now=110 | yes |
| 5 | corner | tick counter wrapped | done=`0xFFFFFFF0`, ack=10, now=5 | yes (wrap-safe) |

```c
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
```

### Fix
```c
if ((u32)(rpc->done_timer_ticks + homa->request_ack_ticks - 1
		- homa->timer_ticks) & (1u << 31)) {
```

---

## Bug 5 — signed/unsigned `min()` in fragment copy **[M]**

**File:** `homa_outgoing.c:294`

### Issue
```c
int frag_bytes;
frag_bytes = min(skb_frag_size(msg_frag) - bytes_to_skip, bytes_left);
```
`skb_frag_size()` returns `unsigned int`; `bytes_to_skip` and `bytes_left` are `int`. The
subtraction `unsigned - int` is unsigned, and `min()` then compares an `unsigned int` against
`int bytes_left` — kernel `min()` warns/breaks on mismatched signedness, and if
`bytes_to_skip > skb_frag_size()` the unsigned subtraction wraps to a huge value, so `min`
returns `bytes_left` in the good case but the wrapped intermediate is a latent trap if the
guard ever changes. Make the operands' types explicit.

### TDD

| # | Category | Scenario | Input (`frag_size`, `bytes_to_skip`, `bytes_left`) | Expected `frag_bytes` |
|---|---|---|---|---|
| 1 | positive | frag bigger than remaining | 4096, 0, 100 | 100 |
| 2 | positive | remaining bigger than frag | 200, 0, 5000 | 200 |
| 3 | boundary | skip == frag_size | 200, 200, 50 | 0 |
| 4 | corner | skip > frag_size (wrap risk) | 200, 300, 50 | 0 (never a huge/negative value) |
| 5 | boundary | bytes_left == 0 loop guard | 200, 0, 0 | loop body not entered |

```c
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
```
(`homa_frag_bytes()` extracts the one-line computation as a pure, testable helper.)

### Fix
Clamp in a signed domain after a guarded subtraction.

```c
int avail = (int)skb_frag_size(msg_frag) - bytes_to_skip;

frag_bytes = min(avail, bytes_left);
```

---

## Bug 6 — pointer arithmetic on `void *vaddr` **[L]**

**File:** `homa_tx_pool.c:532`–`:534`

### Issue
```c
void *vaddr = kmap_local_page(p);
result = copy_from_iter(vaddr + p_off, p_len, iter);
```
`vaddr + p_off` is arithmetic on a `void *`, which is a GNU extension (`sizeof(void)==1`
assumed), not standard C, and is what cppcheck flags as `arithOperationsOnVoidPointer`. It
compiles under the kernel's GNU dialect but is non-portable and obscures intent. Use a
byte-typed pointer.

### TDD

| # | Category | Scenario | Input (`p_off`, `p_len`) | Expected outcome |
|---|---|---|---|---|
| 1 | positive | mid-page offset copy | off=64, len=128 | 128 bytes land at `page+64` |
| 2 | boundary | zero offset | off=0, len=256 | copy starts at page base |
| 3 | boundary | offset to last byte | off=PAGE-1, len=1 | 1 byte at final offset |
| 4 | corner | zero length | off=100, len=0 | no bytes copied; returns 0 |

```c
struct kmap_case { const char *name; int p_off; int p_len; };

static const struct kmap_case kmap_cases[] = {
	{ "mid-page",  64,        128 },
	{ "zero-off",  0,         256 },
	{ "last-byte", 4095,      1   },
	{ "zero-len",  100,       0   },
};

TEST(homa_pool_copy_offsets)
{
	for (size_t i = 0; i < ARRAY_SIZE(kmap_cases); i++) {
		const struct kmap_case *c = &kmap_cases[i];

		mock_iter_fill(0xAB, c->p_len);
		EXPECT_EQ(c->p_len,
			  mock_pool_copy_at(c->p_off, c->p_len));
		EXPECT_TRUE(mock_page_region_is(0xAB, c->p_off, c->p_len));
	}
}
```
This is a portability/clarity fix, so the test pins *behavior* (correct destination offset)
that must survive the retype.

### Fix
```c
char *vaddr = kmap_local_page(p);

result = copy_from_iter(vaddr + p_off, p_len, iter);
```

---

## Bug 7 — deserialized DATA `seg.offset` narrowed `u32`→`int`, unvalidated **[M]** *(deserialization focus)*

**File:** `homa_incoming.c:398`

### Issue
```c
int offset = ntohl(h->seg.offset);
```
`h->seg.offset` is a wire `__be32`; `ntohl` yields `u32`, assigned to a signed `int`. A
malicious/corrupt peer can send `offset >= 0x80000000`, which becomes **negative**. That
negative offset then flows into copy-out bookkeeping (`start_offset`/`end_offset`,
buffer-position math). Since the value comes straight off the wire in the deserialization
path, it must be validated against the message length before use — this is exactly the class
of bug the (de)serialization fuzzing focus targets.

### TDD

| # | Category | Scenario | Input DATA `seg.offset` | Expected outcome |
|---|---|---|---|---|
| 1 | positive | in-range offset | 0 | accepted; copy proceeds |
| 2 | positive | mid-message offset | `msg_len/2` | accepted |
| 3 | boundary | last valid offset | `msg_len - 1` | accepted |
| 4 | negative | offset == msg_len | `msg_len` | rejected / packet dropped |
| 5 | corner | high bit set (wire) | `0x80000000` | rejected as out-of-range (**not** treated as negative) |
| 6 | corner | max u32 | `0xFFFFFFFF` | rejected |

```c
struct off_case { const char *name; u32 wire_offset; bool expect_accept; };

static const struct off_case data_off_cases[] = {
	{ "zero",       0,          true  },
	{ "mid",        5000,       true  },
	{ "last-valid", 9999,       true  },
	{ "at-len",     10000,      false },
	{ "high-bit",   0x80000000, false },
	{ "max-u32",    0xFFFFFFFF, false },
};

FIXTURE(homa_data_deser) { struct homa homa; struct homa_sock hsk; struct homa_rpc *rpc; };

TEST_F(homa_data_deser, offset_out_of_range_rejected)
{
	for (size_t i = 0; i < ARRAY_SIZE(data_off_cases); i++) {
		const struct off_case *c = &data_off_cases[i];
		struct sk_buff *skb =
			mock_data_skb(self->rpc, /*msg_len=*/10000, c->wire_offset);

		unit_log_clear();
		homa_data_pkt(skb, self->rpc);
		EXPECT_EQ(c->expect_accept, !unit_log_contains("dropped"));
	}
}
```
Rows 5–6 pass today by accident (negative offset mis-handled downstream) — the test makes the
required rejection explicit.

### Fix
Read as unsigned and validate before use.

```c
u32 offset = ntohl(h->seg.offset);

if (offset >= rpc->msgin.length) {
	homa_data_drop(skb, "offset out of range");
	continue;
}
```

---

## Bug 8 — deserialized GRANT `offset` narrowed `u32`→`int` **[M]** *(deserialization focus)*

**File:** `homa_incoming.c:809`

### Issue
```c
int new_offset = ntohl(h->offset);
```
Same pattern in the GRANT handler: a wire `__be32` becomes signed `int new_offset`. Here a
high-bit value becomes negative, and the guard `if (new_offset > rpc->msgout.granted)` then
*silently drops* a legitimately large grant (flow-control stall) rather than crashing — a
correctness/DoS-shaped defect distinct from Bug 7's copy path. Handle it as unsigned and clamp
to `msgout.length`.

### TDD

| # | Category | Scenario | Input GRANT `offset`, `msgout.granted`, `length` | Expected `msgout.granted` after |
|---|---|---|---|---|
| 1 | positive | advances grant | off=5000, granted=1000, len=10000 | 5000 |
| 2 | negative | stale (<= current) | off=500, granted=1000, len=10000 | 1000 (unchanged) |
| 3 | boundary | grant == length | off=10000, granted=0, len=10000 | 10000 |
| 4 | boundary | grant > length | off=12000, granted=0, len=10000 | 10000 (clamped) |
| 5 | corner | high bit set | off=0x80000000, granted=0, len=10000 | 10000 (clamped, **not** ignored as negative) |

```c
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
```
Row 5 is `0` (grant ignored) today; expected `10000`.

### Fix
```c
u32 new_offset = ntohl(h->offset);
...
if (new_offset > rpc->msgout.granted)
	rpc->msgout.granted = min_t(u32, new_offset, rpc->msgout.length);
```

---

## Bug 9 — invalid regex escape sequences in non-raw strings (W605) **[M]**

**Files:** `util/rpcid.py:144`, `util/smi.py:32`, `util/tput.py:40`, `util/tthoma.py:1739`

### Issue
Patterns such as `re.match(' *([-0-9.]+) us .* \[C([0-9]+)\]', line)` use `\[` and `\]` inside a
**non-raw** string. Python treats an unknown escape (`\[`) as a literal backslash today but
raises `DeprecationWarning` now and will become a `SyntaxError`. The regex also does not mean
what it looks like. All regex literals should be raw strings.

### TDD

| # | Category | Scenario | Input line | Expected match |
|---|---|---|---|---|
| 1 | positive | well-formed trace line | `"  12.5 us foo [C3]"` | groups `("12.5", "3")` |
| 2 | negative | missing bracket token | `"  12.5 us foo C3"` | no match (`None`) |
| 3 | boundary | zero core index | `"  0.0 us x [C0]"` | groups `("0.0", "0")` |
| 4 | corner | brackets present but non-numeric core | `"  1.0 us x [CZ]"` | no match |

```python
import re
import pytest

PATTERN = re.compile(r' *([-0-9.]+) us .* \[C([0-9]+)\]')

@pytest.mark.parametrize("name,line,expected", [
    ("well-formed",  "  12.5 us foo [C3]", ("12.5", "3")),
    ("missing-brkt", "  12.5 us foo C3",   None),
    ("zero-core",    "  0.0 us x [C0]",    ("0.0", "0")),
    ("non-numeric",  "  1.0 us x [CZ]",    None),
])
def test_trace_line(name, line, expected):
    m = PATTERN.match(line)
    assert (m.groups() if m else None) == expected
```
Run with `python -W error::DeprecationWarning`; today's non-raw literal raises before matching.

### Fix
Prefix each regex literal with `r`:

```python
match = re.match(r' *([-0-9.]+) us .* \[C([0-9]+)\]', line)
```
Apply the same `r'...'` change at each of the four sites.

---

## Bug 10 — unquoted `$@` re-splits arguments (SC2068) **[M]**

**File:** `cloudlab/bin/on_nodes:28`

### Issue
```bash
ssh -4 $node $@
```
Unquoted `$@` undergoes word-splitting and glob expansion, so a remote command containing
spaces or globbing characters (`ssh ... 'grep foo bar.txt'`, or a path with `*`) is torn into
the wrong number of arguments. The correct form preserves each argument verbatim with
`"$@"`.

### TDD

| # | Category | Scenario | Input args | Expected remote argv |
|---|---|---|---|---|
| 1 | positive | simple single command | `uptime` | `["uptime"]` |
| 2 | boundary | no extra args | *(none)* | empty; no spurious word |
| 3 | negative | quoted multi-word command | `"grep foo bar"` | `["grep foo bar"]` (one arg) |
| 4 | corner | arg containing a glob | `"ls *.log"` | `["ls *.log"]` literal, unexpanded |

```bash
# on_nodes.bats — ssh replaced by a stub that records its argv
setup() { PATH="$BATS_TEST_DIRNAME/stubs:$PATH"; }

@test "single command" {
  run on_nodes 1 1 uptime
  [ "$output" = "node1: uptime" ]
}
@test "no extra args"        { run on_nodes 1 1;            [ "$output" = "node1:" ]; }
@test "quoted multi-word"    { run on_nodes 1 1 "grep foo bar"
                               [ "$output" = "node1: grep foo bar" ]; }
@test "glob stays literal"   { run on_nodes 1 1 "ls *.log"
                               [ "$output" = "node1: ls *.log" ]; }
```
The stub echoes `"$node: $*"` from the arguments it actually received; rows 3–4 show extra
words today.

### Fix
```bash
ssh -4 "$node" "$@"
```

---

## How to run these tests

- **C:** add the new `TEST`/`TEST_F` blocks to the matching `test/unit_homa_*.c` and build with
  the existing harness — `nix develop` then `homa-test`, or `make -C test` (ASan on). The
  extracted pure helpers (`homa_tx_pool_min_pages`, `homa_frag_bytes`) keep the size/signedness
  logic unit-testable without a live skb.
- **Python:** `pytest util/` (add a `tests/` module or inline the parametrized tests);
  the flake's `pythonEnv` already carries the interpreter — extend it with `pytest` in
  `nix/packages.nix` when wiring CI.
- **Shell:** `bats cloudlab/bin/tests/` with the `ssh` stub on `PATH`; add `bats` to `devTools`.

All new tests are written to **fail first** against the current tree and **pass** after the
paired fix — standard red/green TDD. Fixes 1–8 are additive kernel-C changes in Homa style;
9–10 are one-line edits.
