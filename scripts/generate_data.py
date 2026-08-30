#!/usr/bin/env python3
"""
Overlay Lab :: sample data generator

Writes metrology CSV files into ./data for the ingest service to pick up.
Standard library only - runs with any Python 3 on the host.

    python3 scripts/generate_data.py              # 3 normal wafers
    python3 scripts/generate_data.py --bad        # plus one malformed file
    python3 scripts/generate_data.py --drift      # a wafer with a shifted mean
"""

import argparse
import os
import random
from datetime import datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(os.path.dirname(HERE), "data")

HEADER = [
    "lot", "wafer_slot", "layer", "tool_id", "measured_at",
    "field_x", "field_y", "die_x", "die_y", "overlay_x_nm", "overlay_y_nm",
]


def write_wafer(lot, slot, layer, tool, when, bias_x=0.0, bias_y=0.0, noise=1.8):
    """One wafer: a 7x7 grid of fields, 4 measurement sites per field."""
    name = f"{lot}_slot{slot:02d}_{layer}.csv"
    path = os.path.join(DATA_DIR, name)
    rows = []
    for fx in range(-3, 4):
        for fy in range(-3, 4):
            for dx, dy in ((0, 0), (1, 0), (0, 1), (1, 1)):
                # A small radial term makes the data look like a real wafer
                # signature rather than pure noise.
                radial = 0.35 * (fx ** 2 + fy ** 2) ** 0.5
                ox = random.gauss(bias_x + radial * 0.4, noise)
                oy = random.gauss(bias_y - radial * 0.3, noise)
                rows.append([
                    lot, slot, layer, tool, when.strftime("%Y-%m-%d %H:%M:%S"),
                    fx, fy, dx, dy, f"{ox:.3f}", f"{oy:.3f}",
                ])

    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(",".join(HEADER) + "\n")
        for r in rows:
            fh.write(",".join(str(v) for v in r) + "\n")
    print(f"wrote {name} ({len(rows)} points)")


def write_bad_file():
    """Missing the overlay_y_nm column. The ingest service must reject this
    cleanly and record why in dbo.IngestLog - that is the whole point."""
    name = "LOT9999_slot01_METAL1.csv"
    path = os.path.join(DATA_DIR, name)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write("lot,wafer_slot,layer,tool_id,measured_at,"
                 "field_x,field_y,die_x,die_y,overlay_x_nm\n")
        fh.write("LOT9999,1,METAL1,ARCHER-01,2026-08-24 09:15:00,0,0,0,0,1.234\n")
    print(f"wrote {name} (deliberately malformed)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bad", action="store_true", help="also write a malformed file")
    ap.add_argument("--drift", action="store_true", help="write a wafer with a shifted mean")
    ap.add_argument("--lot", default=None, help="lot name (default: time-based)")
    args = ap.parse_args()

    os.makedirs(DATA_DIR, exist_ok=True)
    lot = args.lot or "LOT" + datetime.now().strftime("%m%d%H%M")
    base = datetime.now() - timedelta(minutes=30)

    for slot in (1, 2, 3):
        write_wafer(lot, slot, "VIA1", "ARCHER-01", base + timedelta(minutes=slot * 3))

    if args.drift:
        # Mean overlay pushed well off zero: what a scanner correction is meant
        # to catch. Compare MeanX_nm in dbo.vw_RunSummary against the others.
        write_wafer(lot, 9, "VIA1", "ARCHER-01",
                    base + timedelta(minutes=30), bias_x=6.5, bias_y=-4.0)

    if args.bad:
        write_bad_file()


if __name__ == "__main__":
    main()
