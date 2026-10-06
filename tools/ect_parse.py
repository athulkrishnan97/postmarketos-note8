#!/usr/bin/env python3
"""Parse an Exynos ECT ("PARA") dump and print a DVFS domain's ASV voltages.

Port of the downstream drivers/soc/samsung/ect_parser.c (header, ASV and
MARGIN blocks).  Usage:

    ect_parse.py ect.bin [domain] [asv_table_ver] [group]

Without table/group it prints every table; with them it prints the
voltage (step * 6.25 mV + MARGIN offset) per level for that chip.
"""
import struct
import sys

STEP_UV = 6250  # PMIC_VOLTAGE_STEP


class Reader:
    def __init__(self, buf, off):
        self.buf, self.off = buf, off

    def u32(self):
        v = struct.unpack_from("<I", self.buf, self.off)[0]
        self.off += 4
        return v

    def s32(self):
        v = struct.unpack_from("<i", self.buf, self.off)[0]
        self.off += 4
        return v

    def string(self):
        n = self.u32() + 1
        s = self.buf[self.off:self.off + n].split(b"\0")[0].decode()
        self.off += n + (-n % 4)
        return s


def blocks(buf):
    r = Reader(buf, 0)
    sign = buf[0:4]
    if sign != b"PARA":
        sys.exit(f"bad signature {sign!r}")
    r.off = 8
    total, n = r.u32(), r.u32()
    out = {}
    for _ in range(n):
        name = r.string()
        out[name] = r.u32()
    return out


def named_list(buf, base):
    r = Reader(buf, base)
    pver, ver, n = r.u32(), r.u32(), r.u32()
    doms = []
    for _ in range(n):
        name = r.string()
        doms.append((name, base + r.u32()))
    return pver, doms


def asv_domain(buf, off, pver):
    r = Reader(buf, off)
    ngrp, nlvl, ntbl = r.u32(), r.u32(), r.u32()
    levels = [r.s32() for _ in range(nlvl)]
    tables = []
    for _ in range(ntbl):
        tver = r.u32()
        if pver >= 2:
            r.u32(); r.u32()                     # boot/resume level
            r.off += 4 * nlvl                    # level_en
        if pver >= 3:
            data = list(buf[r.off:r.off + ngrp * nlvl])
            r.off += ngrp * nlvl
            volts = [d * STEP_UV for d in data]
        else:
            volts = [r.s32() for _ in range(ngrp * nlvl)]
        tables.append((tver, volts))
    return ngrp, levels, tables


def margin_domain(buf, off, pver):
    r = Reader(buf, off)
    ngrp, nlvl = r.u32(), r.u32()
    if pver >= 2:
        raw = struct.unpack_from(f"<{ngrp * nlvl}b", buf, r.off)
        return ngrp, [v * STEP_UV for v in raw]
    return ngrp, [r.s32() for _ in range(ngrp * nlvl)]


def main():
    buf = open(sys.argv[1], "rb").read()
    dom = sys.argv[2] if len(sys.argv) > 2 else "dvfs_g3d"
    tver = int(sys.argv[3]) if len(sys.argv) > 3 else None
    grp = int(sys.argv[4]) if len(sys.argv) > 4 else None

    blk = blocks(buf)
    print("blocks:", ", ".join(blk))

    pver, doms = named_list(buf, blk["ASV"])
    print("ASV domains:", ", ".join(d for d, _ in doms))
    off = dict(doms)[dom]
    ngrp, levels, tables = asv_domain(buf, off, pver)

    margin = None
    if "MARGIN" in blk:
        mpver, mdoms = named_list(buf, blk["MARGIN"])
        if dom in dict(mdoms):
            margin = margin_domain(buf, dict(mdoms)[dom], mpver)

    print(f"{dom}: {ngrp} groups, levels (kHz) {levels}")
    for tv, volts in tables:
        if tver is not None and tv != tver:
            continue
        print(f"-- table version {tv}")
        for li, f in enumerate(levels):
            row = []
            for g in range(ngrp):
                v = volts[li * ngrp + g]
                if margin:
                    v += margin[1][li * margin[0] + g]
                row.append(v)
            if grp is not None:
                print(f"  {f:>8} kHz: group {grp} -> {row[grp]} uV")
            else:
                print(f"  {f:>8} kHz: " + " ".join(f"{v // 1000:4d}" for v in row) + " mV")


if __name__ == "__main__":
    main()
