#!/usr/bin/env bash
# patch-autoconf.sh <in autoconf.h> <out autoconf.h>
# Adapts a distro kernel config to what Homa's user-space mock layer (test/mock.[ch]) assumes.
set -eu
awk '
BEGIN {
  split("CONFIG_USE_X86_SEG_SUPPORT CONFIG_CC_HAS_NAMED_AS CONFIG_CC_HAS_NAMED_AS_FIXED_SANITIZERS CONFIG_MEM_ALLOC_PROFILING CONFIG_MEM_ALLOC_PROFILING_ENABLED_BY_DEFAULT CONFIG_MEM_ALLOC_PROFILING_DEBUG", a, " ")
  for (i in a) off[a[i]] = 1
}
$1 == "#define" && ($2 in off) { print "/* unit-test KDIR: " $2 " disabled */"; next }
{ print }
END { print "#ifndef CONFIG_DEBUG_PREEMPT\n#define CONFIG_DEBUG_PREEMPT 1 /* unit-test KDIR */\n#endif" }
' "$1" > "$2"
