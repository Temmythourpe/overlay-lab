"""
Overlay Lab :: ingest service

Watches /data for metrology CSV files, loads them into SQL Server, and writes
one row to dbo.IngestLog for every file it touches - success or failure.

Deliberately simple. The point of this service is to be something you have to
keep running and diagnose, not something clever.
"""

import csv
import os
import shutil
import sys
import time
from datetime import datetime, timezone

import pymssql

DB_HOST = os.environ.get("DB_HOST", "sqlserver")
DB_USER = os.environ.get("DB_USER", "sa")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_NAME = os.environ.get("DB_NAME", "OverlayLab")
DATA_DIR = os.environ.get("DATA_DIR", "/data")
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "20"))

PROCESSED_DIR = os.path.join(DATA_DIR, "processed")
FAILED_DIR = os.path.join(DATA_DIR, "failed")

REQUIRED_COLUMNS = [
    "lot", "wafer_slot", "layer", "tool_id", "measured_at",
    "field_x", "field_y", "die_x", "die_y", "overlay_x_nm", "overlay_y_nm",
]


def log(msg):
    """Everything goes to stdout so `docker logs` is the single place to look."""
    print(f"{datetime.now(timezone.utc).isoformat(timespec='seconds')}  {msg}", flush=True)


def connect(database=None):
    return pymssql.connect(
        server=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
        database=database or DB_NAME,
        timeout=15,
        login_timeout=15,
    )


def wait_for_db(max_attempts=30):
    for attempt in range(1, max_attempts + 1):
        try:
            conn = connect()
            conn.close()
            log(f"connected to {DB_HOST}/{DB_NAME}")
            return
        except Exception as exc:
            log(f"waiting for database (attempt {attempt}/{max_attempts}): {exc}")
            time.sleep(5)
    log("FATAL: database never became reachable")
    sys.exit(1)


def get_or_create_lot(cur, lot_name):
    cur.execute("SELECT LotID FROM dbo.Lot WHERE LotName = %s", (lot_name,))
    row = cur.fetchone()
    if row:
        return row[0]
    cur.execute(
        "INSERT INTO dbo.Lot (LotName) OUTPUT INSERTED.LotID VALUES (%s)", (lot_name,)
    )
    return cur.fetchone()[0]


def get_or_create_wafer(cur, lot_id, slot_no):
    cur.execute(
        "SELECT WaferID FROM dbo.Wafer WHERE LotID = %s AND SlotNo = %s",
        (lot_id, slot_no),
    )
    row = cur.fetchone()
    if row:
        return row[0]
    cur.execute(
        "INSERT INTO dbo.Wafer (LotID, SlotNo) OUTPUT INSERTED.WaferID VALUES (%s, %s)",
        (lot_id, slot_no),
    )
    return cur.fetchone()[0]


def create_run(cur, wafer_id, layer, tool_id, measured_at, source_file):
    cur.execute(
        """INSERT INTO dbo.MeasurementRun (WaferID, Layer, ToolID, MeasuredAt, SourceFile)
           OUTPUT INSERTED.RunID VALUES (%s, %s, %s, %s, %s)""",
        (wafer_id, layer, tool_id, measured_at, source_file),
    )
    return cur.fetchone()[0]


def record_ingest(file_name, rows_read, rows_inserted, status, message):
    """Written on its own connection so a rolled-back load still leaves a trace."""
    try:
        conn = connect()
        cur = conn.cursor()
        cur.execute(
            """INSERT INTO dbo.IngestLog
               (FileName, RowsRead, RowsInserted, Status, Message, FinishedAt)
               VALUES (%s, %s, %s, %s, %s, SYSUTCDATETIME())""",
            (file_name, rows_read, rows_inserted, status, (message or "")[:2000]),
        )
        conn.commit()
        conn.close()
    except Exception as exc:
        log(f"could not write IngestLog for {file_name}: {exc}")


def load_file(path):
    file_name = os.path.basename(path)
    rows_read = 0
    rows_inserted = 0
    conn = None

    try:
        with open(path, newline="", encoding="utf-8-sig") as fh:
            reader = csv.DictReader(fh)
            missing = [c for c in REQUIRED_COLUMNS if c not in (reader.fieldnames or [])]
            if missing:
                raise ValueError(f"missing required columns: {', '.join(missing)}")
            rows = list(reader)

        if not rows:
            raise ValueError("file contains no data rows")

        conn = connect()
        cur = conn.cursor()

        head = rows[0]
        lot_id = get_or_create_lot(cur, head["lot"])
        wafer_id = get_or_create_wafer(cur, lot_id, int(head["wafer_slot"]))
        run_id = create_run(
            cur, wafer_id, head["layer"], head["tool_id"],
            head["measured_at"], file_name,
        )

        batch = []
        for row in rows:
            rows_read += 1
            batch.append((
                run_id,
                int(row["field_x"]), int(row["field_y"]),
                int(row["die_x"]), int(row["die_y"]),
                float(row["overlay_x_nm"]), float(row["overlay_y_nm"]),
            ))

        cur.executemany(
            """INSERT INTO dbo.OverlayPoint
               (RunID, FieldX, FieldY, DieX, DieY, OverlayX_nm, OverlayY_nm)
               VALUES (%s, %s, %s, %s, %s, %s, %s)""",
            batch,
        )
        rows_inserted = len(batch)
        conn.commit()
        conn.close()

        os.makedirs(PROCESSED_DIR, exist_ok=True)
        shutil.move(path, os.path.join(PROCESSED_DIR, file_name))
        record_ingest(file_name, rows_read, rows_inserted, "SUCCESS", None)
        log(f"OK    {file_name}: {rows_inserted} points into run {run_id}")

    except Exception as exc:
        if conn:
            try:
                conn.rollback()
                conn.close()
            except Exception:
                pass
        os.makedirs(FAILED_DIR, exist_ok=True)
        try:
            shutil.move(path, os.path.join(FAILED_DIR, file_name))
        except Exception:
            pass
        record_ingest(file_name, rows_read, 0, "FAILED", str(exc))
        log(f"FAIL  {file_name}: {exc}")

def main():
    log(f"ingest service starting; watching {DATA_DIR} every {POLL_SECONDS}s")
    wait_for_db()
    while True:
        try:
            entries = sorted(
                f for f in os.listdir(DATA_DIR)
                if f.lower().endswith(".csv")
                and os.path.isfile(os.path.join(DATA_DIR, f))
            )
            for name in entries:
                load_file(os.path.join(DATA_DIR, name))
        except Exception as exc:
            log(f"poll loop error: {exc}")
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()