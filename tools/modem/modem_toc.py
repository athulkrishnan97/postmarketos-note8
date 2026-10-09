#!/usr/bin/env python3
"""Dump the TOC of a Shannon modem image (RADIO partition / modem.bin).

The image starts with a table of 32-byte entries:
    char name[12]; u32 b_offset; u32 m_offset; u32 size; u32 crc; u32 misc;
b_offset is the offset in the file, m_offset the load offset inside the CP
shared memory (cbd: "TOC[%d].name = %s, b_off, m_off, size, crc").
The first entry is "TOC" itself; the table ends at the first empty name.

Usage: modem_toc.py RADIO.img [--extract DIR]
"""
import struct
import sys
import os


def read_toc(data):
    entries = []
    for i in range(0, 32 * 16, 32):
        name, b_off, m_off, size, crc, misc = struct.unpack_from("<12s5I", data, i)
        name = name.split(b"\0", 1)[0].decode("ascii", "replace")
        if not name:
            break
        entries.append((name, b_off, m_off, size, crc, misc))
    return entries


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    entries = read_toc(data)
    if not entries or entries[0][0] != "TOC":
        print("warning: first entry is not 'TOC' - not a Shannon image?")
    print(f"{'name':12} {'file off':>10} {'mem off':>10} {'size':>10} {'crc':>10} {'misc':>10}")
    for name, b_off, m_off, size, crc, misc in entries:
        print(f"{name:12} {b_off:#010x} {m_off:#010x} {size:#010x} {crc:#010x} {misc:#010x}")
    if len(sys.argv) > 3 and sys.argv[2] == "--extract":
        out = sys.argv[3]
        os.makedirs(out, exist_ok=True)
        for name, b_off, m_off, size, crc, misc in entries:
            if size and b_off + size <= len(data):
                with open(os.path.join(out, name + ".bin"), "wb") as f:
                    f.write(data[b_off:b_off + size])
        print(f"extracted to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
