#!/usr/bin/env python3
"""Generate seed inputs for the kernel-mock fuzzers (nix/fuzz/harness/mock).

Usage: gen-mock-seeds.py <out-dir>

Each seed is: scenario byte, flags byte, then [u16 LE length][packet] records
(see fuzz_softirq.c). Flags bit 0 is set so the harness aims the packets at
the scenario's RPC; only the type-specific fields need to be plausible.
"""

import os
import struct
import sys

DATA, GRANT, RESEND, RPC_UNKNOWN, BUSY, CUTOFFS = 0x10, 0x11, 0x12, 0x13, 0x14, 0x15
NEED_ACK, ACK, START_MSG = 0x17, 0x18, 0x19


def common(ptype):
    # sport, dport, sequence, ack[3], type, doff, flags, window, checksum,
    # urgent, sender_id (the harness overwrites ports and sender_id).
    return struct.pack(">HHI3sBBBHHHQ", 0, 0, 0, b"\0\0\0", ptype, 0, 0, 0, 0, 0, 0)


def homa_ack(client_id=0, port=0):
    return struct.pack(">QH", client_id, port)


def data(msg_length, offset, payload=1000, retransmit=0):
    hdr = (common(DATA) + struct.pack(">II", msg_length, 0) + homa_ack()
           + struct.pack(">HHB3s", 0, 0, retransmit, b"\0\0\0")
           + struct.pack(">I", offset))
    return hdr + bytes((i & 0xff for i in range(payload)))


def grant(offset, priority=0):
    return common(GRANT) + struct.pack(">IB", offset, priority)


def resend(offset, length, priority=0):
    return common(RESEND) + struct.pack(">IIB", offset, length, priority)


def start_msg(msg_length):
    return common(START_MSG) + struct.pack(">I", msg_length)


def ack(acks):
    body = b"".join(homa_ack(c, p) for c, p in acks)
    body += homa_ack() * (5 - len(acks))
    return common(ACK) + struct.pack(">H", len(acks)) + body


def cutoffs(version=1):
    vals = [1000000, 12288, 8192, 4096, 2048, 1024, 512, 256]
    return common(CUTOFFS) + struct.pack(">8IH", *vals, version)


def seed(scenario, *pkts, flags=1):
    out = bytes([scenario, flags])
    for p in pkts:
        out += struct.pack("<H", len(p)) + p
    return out


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    seeds = {
        # Client RPCs (scenarios 1, 2, 7): response packets from the server.
        "c_resp_data": seed(1, data(10000, 0), data(10000, 1000)),
        "c_resp_start": seed(1, start_msg(3000), data(3000, 0)),
        "c_grant": seed(1, grant(5000, 1), grant(20000)),
        "c_resend": seed(1, resend(0, 1000), resend(500, 100000)),
        "c_busy": seed(2, common(BUSY)),
        "c_unknown": seed(1, common(RPC_UNKNOWN)),
        "c_cutoffs": seed(1, cutoffs()),
        "c_need_ack": seed(7, common(NEED_ACK)),
        "c_retransmit": seed(2, data(10000, 1400, retransmit=1)),
        # Server RPCs (scenarios 3-5): request packets from the client.
        "s_req_data": seed(3, data(10000, 1400), data(10000, 2800)),
        "s_resend": seed(5, resend(0, 1400), resend(1400, 1400)),
        "s_grant": seed(5, grant(15000)),
        "s_ack": seed(4, ack([(1234, 99)])),
        "s_need_ack": seed(4, common(NEED_ACK)),
        # No RPC: new incoming request and stray packets.
        "n_new_req": seed(0, data(5000, 0), data(5000, 1000)),
        "n_new_start": seed(0, start_msg(2000)),
        "n_stray": seed(0, grant(100), resend(0, 10), common(BUSY)),
        # Both a client and a server RPC.
        "both": seed(6, data(1000, 0), grant(30000), flags=1),
        "both_srv": seed(6, data(10000, 1400), flags=5),
        "ipv4": seed(3, data(10000, 1400), flags=3),
    }
    for name, blob in seeds.items():
        with open(os.path.join(out, name), "wb") as f:
            f.write(blob)


if __name__ == "__main__":
    main()
