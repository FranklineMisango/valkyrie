#!/usr/bin/env python3
"""
pcap2axis.py - Convert a PCAP capture into AXI-Stream stimulus for RTL cosim.

Emits one line per 64-bit AXI-Stream beat:
    <tdata hex> <tkeep hex> <tlast bit>
Packets are little-endian, byte 0 of the packet lands in tdata[7:0], and the
last beat of every packet asserts tlast.

Usage:
    python3 pcap2axis.py <in.pcap> <out.axis> [max_packets]
Then drive the RTL with fpga/tb/tb_pcap_replay.v ($readmemh/$fscanf).

Mirrors the parsing in tools/pcap_analyzer.c (nanosecond classic PCAP).
"""
import struct
import sys


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    path, out = argv[1], argv[2]
    limit = int(argv[3]) if len(argv) > 3 else 5000

    with open(path, "rb") as fh:
        blob = fh.read()

    magic = struct.unpack_from("<I", blob, 0)[0]
    if magic == 0xA1B23C4D:
        ts_div = 1e9            # nanosecond
    elif magic == 0xA1B2C3D4:
        ts_div = 1e6            # microsecond
    else:
        print(f"unsupported pcap magic 0x{magic:08x}")
        return 1

    pos, npkt, nbytes, nbeats = 24, 0, 0, 0
    with open(out, "w") as fh:
        while pos + 16 <= len(blob) and npkt < limit:
            ts_sec, ts_nsec, il, ol = struct.unpack_from("<IIII", blob, pos)
            pos += 16
            if pos + il > len(blob):
                break
            pkt = blob[pos:pos + il]
            pos += il
            npkt += 1
            nbytes += il

            # pad to a whole number of 64-bit beats
            nbeats_pkt = (len(pkt) + 7) // 8
            for b in range(nbeats_pkt):
                chunk = pkt[b * 8:(b + 1) * 8]
                keep = (1 << len(chunk)) - 1
                td = 0
                for i, byte in enumerate(chunk):
                    td |= byte << (8 * i)
                last = 1 if b == nbeats_pkt - 1 else 0
                fh.write(f"{td:016x} {keep:02x} {last}\n")
                nbeats += 1

    print(f"pcap2axis: {npkt} packets, {nbytes} bytes, {nbeats} AXI beats -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
