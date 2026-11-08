// SPDX-License-Identifier: BSD-2-Clause or GPL-2.0+
/*
 * fuzz_compat.c - link-time glue for the kernel-mock fuzzers.
 *
 * With -fsanitize=address and CONFIG_GENERIC_ENTRY (but no KASAN), the
 * kernel's fortify-string.h renames memcpy/memset/memmove to the KASAN
 * software-tag symbols. Forward them to libc, where ASan intercepts them.
 */

#include <string.h>

void *__hwasan_memcpy(void *p, const void *q, size_t size)
{
	return memcpy(p, q, size);
}

void *__hwasan_memset(void *p, int c, size_t size)
{
	return memset(p, c, size);
}

void *__hwasan_memmove(void *p, const void *q, size_t size)
{
	return memmove(p, q, size);
}
