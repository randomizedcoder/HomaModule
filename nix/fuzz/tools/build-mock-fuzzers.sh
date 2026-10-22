#!/usr/bin/env bash
# nix/fuzz/tools/build-mock-fuzzers.sh
#
# Builds the kernel-mock libFuzzer harnesses (nix/fuzz/harness/mock/*.c) by
# compiling Homa and the unit-test mock layer exactly the way test/Makefile
# does, but with clang + libFuzzer + ASan/UBSan.
#
# Usage: build-mock-fuzzers.sh <src-dir> <kdir> <out-dir> [extra-cflags]
#   <kdir>          a merged KDIR such as nix/unit-kdir produces
#   [extra-cflags]  e.g. unitKdir.extraCFlags
#
# Writes <out-dir>/bin/<harness>, <out-dir>/status.txt and <out-dir>/build.log.
# Exits non-zero if the shared objects or any harness fail to build.

set -u
SRC=$(cd "$1" && pwd)
KDIR=$2
OUT=$3
EXTRA=${4:-}
CC=${CC:-clang}
CXX=${CXX:-clang++}
JOBS=${JOBS:-$(nproc)}

mkdir -p "$OUT/bin" "$OUT/obj"
OBJ="$OUT/obj"
LOG="$OUT/build.log"
STATUS="$OUT/status.txt"
: > "$LOG"
: > "$STATUS"

INC="-I$SRC/test -I$SRC \
  -I$KDIR/arch/x86/include -I$KDIR/arch/x86/include/generated \
  -I$KDIR/include -I$KDIR/arch/x86/include/uapi \
  -I$KDIR/arch/x86/include/generated/uapi -I$KDIR/include/uapi \
  -I$KDIR/include/generated/uapi -include $KDIR/include/linux/kconfig.h"
DEFS="-D__KERNEL__ -D__UNIT_TEST__ -DKBUILD_MODNAME='\"homa\"' -DCC_USING_FENTRY"
# alignment is off: list_for_each_entry() on an empty list forms container_of(head) for
# cacheline-aligned types, and mock kmalloc() is plain malloc().
SAN="-fsanitize=fuzzer-no-link,address,undefined -fno-sanitize=alignment -fno-sanitize-recover=undefined"
# clang makes this an error by default; it is the 6.18 recvmsg() signature change.
CFLAGS="-std=gnu11 -fms-extensions -fno-pie -g -O1 -fno-omit-frame-pointer -w \
  -Wno-error=incompatible-function-pointer-types $SAN $DEFS $INC $EXTRA"
CXXFLAGS="-std=c++11 -g -O1 -fno-omit-frame-pointer -w $SAN $DEFS -I$SRC/test -I$SRC"

HOMA_SRCS="homa_devel homa_interest homa_incoming homa_outgoing homa_peer
  homa_pool homa_plumbing homa_rpc homa_sock homa_timer homa_tx_pool
  homa_utils timetrace homa_grant homa_hijack homa_metrics homa_offload
  homa_qdisc"
LINUX_OBJS=$(bash "$SRC/test/linux_objs" "$KDIR/include/generated/uapi/linux/version.h")

compile() { # <flags> <src> <obj>
	eval "$CC -c $1 \"$2\" -o \"$3\"" >> "$LOG" 2>&1 ||
		{ echo "FAILED $2" >> "$STATUS"; return 1; }
}

pids=""
shared=""
for m in $HOMA_SRCS; do
	compile "$CFLAGS" "$SRC/$m.c" "$OBJ/$m.o" & pids="$pids $!"
	shared="$shared $OBJ/$m.o"
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
done
for o in $LINUX_OBJS; do
	b=${o%.o}
	case $b in
	# As in test/Makefile: these need -O2 and no ASan.
	rhashtable*|xxhash*) f="$CFLAGS -O2 -fno-sanitize=address" ;;
	*) f="$CFLAGS" ;;
	esac
	compile "$f" "$SRC/test/$b.c" "$OBJ/$o" & pids="$pids $!"
	shared="$shared $OBJ/$o"
done
for m in mock utils; do
	compile "$CFLAGS" "$SRC/test/$m.c" "$OBJ/$m.o" & pids="$pids $!"
	shared="$shared $OBJ/$m.o"
done
# Plain C, no kernel headers.
$CC -c -O1 -g "$SRC/nix/fuzz/harness/mock/fuzz_compat.c" -o "$OBJ/fuzz_compat.o" \
	>> "$LOG" 2>&1 || echo "FAILED fuzz_compat.c" >> "$STATUS"
shared="$shared $OBJ/fuzz_compat.o"
eval "$CXX -c $CXXFLAGS \"$SRC/test/ccutils.cc\" -o \"$OBJ/ccutils.o\"" \
	>> "$LOG" 2>&1 || echo "FAILED ccutils.cc" >> "$STATUS"
shared="$shared $OBJ/ccutils.o"

ok=1
for p in $pids; do wait "$p" || ok=0; done
grep -q FAILED "$STATUS" && ok=0
if [ $ok != 1 ]; then
	echo "shared objects failed; see build.log" >> "$STATUS"
	cat "$STATUS"
	grep -m20 -E 'error|fatal' "$LOG"
	exit 1
fi
echo "shared objects OK ($(basename "$KDIR"))" >> "$STATUS"

# name:source:extra-defines. The PIN_TYPE variants keep the fuzzer inside a
# single packet handler.
HARNESSES="
fuzz_softirq:fuzz_softirq.c:
fuzz_data_pkt:fuzz_softirq.c:-DPIN_TYPE=DATA
fuzz_grant_pkt:fuzz_softirq.c:-DPIN_TYPE=GRANT
fuzz_resend_pkt:fuzz_softirq.c:-DPIN_TYPE=RESEND
fuzz_rpc_unknown_pkt:fuzz_softirq.c:-DPIN_TYPE=RPC_UNKNOWN
fuzz_busy_pkt:fuzz_softirq.c:-DPIN_TYPE=BUSY
fuzz_cutoffs_pkt:fuzz_softirq.c:-DPIN_TYPE=CUTOFFS
fuzz_need_ack_pkt:fuzz_softirq.c:-DPIN_TYPE=NEED_ACK
fuzz_ack_pkt:fuzz_softirq.c:-DPIN_TYPE=ACK
fuzz_start_msg_pkt:fuzz_softirq.c:-DPIN_TYPE=START_MSG
"
rc=0
for h in $HARNESSES; do
	name=${h%%:*}; rest=${h#*:}; file=${rest%%:*}; defs=${rest#*:}
	if compile "$CFLAGS $defs" "$SRC/nix/fuzz/harness/mock/$file" "$OBJ/$name.o" &&
	   $CXX -no-pie -fsanitize=fuzzer,address,undefined $shared "$OBJ/$name.o" \
		-o "$OUT/bin/$name" >> "$LOG" 2>&1; then
		echo "BUILT $name" >> "$STATUS"
	else
		echo "FAILED $name" >> "$STATUS"
		rc=1
	fi
done
cat "$STATUS"
exit $rc
