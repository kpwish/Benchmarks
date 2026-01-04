#!/usr/bin/env python3
"""
NGS ShapeFiles downloader using system curl + DBF extraction + CSV conversion + CSV cleanup/filtering

Pipeline:
1) Download https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/<STATE>.zip using system curl
2) Save ZIP locally as:        ./ngs_sf_archive_downloads/<STATE>.ZIP
3) Extract DBF to:             ./ngs_sf_archive_downloads/dbfs/<STATE>.dbf
4) Convert DBF to raw CSV:     ./ngs_sf_archive_downloads/csvs/<STATE>.csv
5) Clean/filter to CSV:        ./ngs_sf_archive_downloads/csvs/Processed/<STATE>.csv

CSV cleanup/filtering (per your field list):
- Keeps only these fields (case-insensitive, in this exact order):
  data_date, data_srce, pid, name, dec_lat, dec_lon, state, county, marker, setting, last_recv, last_cond, last_recby, ortho_ht
- Removes double-quotes inside values
- Trims leading/trailing whitespace
- Collapses runs of whitespace to a single space

Run:
    python ngs_sf_archives_curl_downloader_dbf_to_csv_filtered_v2_2.py
"""

from __future__ import annotations

import csv
import datetime
import os
import re
import struct
import subprocess
import time
import zipfile
from typing import Dict, List, Tuple

BASE_DIR_URL = "https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/"

OUT_DIR = "ngs_sf_archive_downloads"
DBF_DIR = os.path.join(OUT_DIR, "dbfs")
CSV_DIR = os.path.join(OUT_DIR, "csvs")
PROCESSED_DIR = os.path.join(CSV_DIR, "Processed")

SLEEP_SECONDS_BETWEEN_DOWNLOADS = 0.5

STATE_CODES: Dict[str, str] = {
    "AL": "Alabama",
    "AK": "Alaska",
    "AZ": "Arizona",
    "AR": "Arkansas",
    "CA": "California",
    "CO": "Colorado",
    "CT": "Connecticut",
    "DE": "Delaware",
    "DC": "District of Columbia",
    "FL": "Florida",
    "GA": "Georgia",
    "HI": "Hawaii",
    "ID": "Idaho",
    "IL": "Illinois",
    "IN": "Indiana",
    "IA": "Iowa",
    "KS": "Kansas",
    "KY": "Kentucky",
    "LA": "Louisiana",
    "ME": "Maine",
    "MD": "Maryland",
    "MA": "Massachusetts",
    "MI": "Michigan",
    "MN": "Minnesota",
    "MS": "Mississippi",
    "MO": "Missouri",
    "MT": "Montana",
    "NE": "Nebraska",
    "NV": "Nevada",
    "NH": "New Hampshire",
    "NJ": "New Jersey",
    "NM": "New Mexico",
    "NY": "New York",
    "NC": "North Carolina",
    "ND": "North Dakota",
    "OH": "Ohio",
    "OK": "Oklahoma",
    "OR": "Oregon",
    "PA": "Pennsylvania",
    "RI": "Rhode Island",
    "SC": "South Carolina",
    "SD": "South Dakota",
    "TN": "Tennessee",
    "TX": "Texas",
    "UT": "Utah",
    "VT": "Vermont",
    "VA": "Virginia",
    "WA": "Washington",
    "WV": "West Virginia",
    "WI": "Wisconsin",
    "WY": "Wyoming",
}

# Fields to keep in the "Processed" CSV (case-insensitive match), in this exact order.
RELEVANT_FIELDS: List[str] = ['data_date', 'data_srce', 'pid', 'name', 'dec_lat', 'dec_lon', 'state', 'county', 'marker', 'setting', 'last_recv', 'last_cond', 'last_recby', 'ortho_ht']

_WS_RE = re.compile(r"\s+")


def _ensure_dirs() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(DBF_DIR, exist_ok=True)
    os.makedirs(CSV_DIR, exist_ok=True)
    os.makedirs(PROCESSED_DIR, exist_ok=True)


def _download_with_curl(url: str, out_path: str) -> None:
    tmp_path = out_path + ".part"
    cmd = [
        "curl",
        "-fL",
        "--retry", "5",
        "--retry-delay", "1",
        "--connect-timeout", "20",
        "--max-time", "300",
        "-o", tmp_path,
        url,
    ]
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"curl failed for {url}\nSTDERR: {(e.stderr or '').strip()}") from e

    if not zipfile.is_zipfile(tmp_path):
        raise RuntimeError(f"Downloaded file is not a valid ZIP: {tmp_path}")

    os.replace(tmp_path, out_path)


def _extract_dbf(zip_path: str, state_code: str) -> str | None:
    out_path = os.path.join(DBF_DIR, f"{state_code}.dbf")
    if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
        return out_path

    with zipfile.ZipFile(zip_path, "r") as z:
        dbf_members = [m for m in z.namelist() if m.lower().endswith(".dbf")]
        if not dbf_members:
            return None

        if len(dbf_members) > 1:
            print(f"  Warning: multiple DBFs found in {os.path.basename(zip_path)}; using first only.")

        member = dbf_members[0]
        with z.open(member) as src, open(out_path, "wb") as dst:
            dst.write(src.read())

    return out_path


def _parse_dbf_header_and_fields(f) -> Tuple[int, int, List[Tuple[str, str, int, int]]]:
    header = f.read(32)
    if len(header) < 32:
        raise ValueError("File too short to be a DBF.")

    num_records = struct.unpack("<I", header[4:8])[0]
    header_len = struct.unpack("<H", header[8:10])[0]
    record_len = struct.unpack("<H", header[10:12])[0]

    fields: List[Tuple[str, str, int, int]] = []
    while True:
        desc = f.read(32)
        if not desc or len(desc) < 32:
            raise ValueError("Unexpected EOF reading DBF field descriptors.")
        if desc[0] == 0x0D:  # terminator
            break

        name = desc[0:11].split(b"\x00", 1)[0].decode("ascii", errors="ignore").strip()
        ftype = chr(desc[11])
        flen = desc[16]
        fdec = desc[17]
        fields.append((name, ftype, flen, fdec))

    f.seek(header_len)
    return num_records, record_len, fields


def _parse_dbf_value(raw: bytes, ftype: str, dec: int, encoding: str) -> object:
    s = raw.decode(encoding, errors="replace")
    if ftype == "C":
        return s.rstrip()
    if ftype in ("N", "F"):
        st = s.strip()
        if st == "":
            return ""
        try:
            if "." in st or dec > 0:
                return float(st)
            return int(st)
        except Exception:
            return st
    if ftype == "L":
        ch = s[:1].upper()
        if ch in ("Y", "T"):
            return True
        if ch in ("N", "F"):
            return False
        return ""
    if ftype == "D":
        st = s.strip()
        if len(st) == 8 and st.isdigit():
            try:
                d = datetime.date(int(st[0:4]), int(st[4:6]), int(st[6:8]))
                return d.isoformat()
            except Exception:
                return st
        return ""
    return s.strip()


def dbf_to_csv(dbf_path: str, csv_path: str, encoding: str = "latin-1") -> None:
    if os.path.exists(csv_path) and os.path.getsize(csv_path) > 0:
        return

    with open(dbf_path, "rb") as f:
        num_records, record_len, fields = _parse_dbf_header_and_fields(f)
        field_names = [n for (n, _, _, _) in fields]

        with open(csv_path, "w", newline="", encoding="utf-8") as out:
            writer = csv.DictWriter(out, fieldnames=field_names)
            writer.writeheader()

            for _ in range(num_records):
                rec = f.read(record_len)
                if not rec or len(rec) < record_len:
                    break
                if rec[0:1] == b"*":
                    continue

                row = {}
                offset = 1
                for name, ftype, flen, fdec in fields:
                    raw = rec[offset:offset + flen]
                    row[name] = _parse_dbf_value(raw, ftype, fdec, encoding)
                    offset += flen

                writer.writerow(row)


def _clean_value(value: object) -> str:
    if value is None:
        return ""
    s = str(value)
    s = s.replace('"', "")
    s = s.strip()
    s = _WS_RE.sub(" ", s)
    return s


def clean_and_filter_csv(input_csv: str, output_csv: str) -> None:
    if os.path.exists(output_csv) and os.path.getsize(output_csv) > 0:
        return

    with open(input_csv, "r", newline="", encoding="utf-8") as infile:
        reader = csv.DictReader(infile)
        if reader.fieldnames is None:
            raise RuntimeError(f"No headers found in {input_csv}")

        header_map = {h.lower(): h for h in reader.fieldnames}

        out_headers: List[str] = []
        missing: List[str] = []
        for want in RELEVANT_FIELDS:
            actual = header_map.get(want.lower())
            if actual:
                out_headers.append(actual)
            else:
                missing.append(want)

        if not out_headers:
            raise RuntimeError(
                f"None of the configured RELEVANT_FIELDS were found in {input_csv}. "
                "Check field names/casing."
            )

        if missing:
            print(f"  Note: {os.path.basename(input_csv)} missing fields (skipped): {', '.join(missing)}")

        with open(output_csv, "w", newline="", encoding="utf-8") as outfile:
            writer = csv.DictWriter(outfile, fieldnames=out_headers)
            writer.writeheader()
            for row in reader:
                cleaned = {h: _clean_value(row.get(h, "")) for h in out_headers}
                writer.writerow(cleaned)


def main() -> None:
    _ensure_dirs()

    for code, name in STATE_CODES.items():
        server_name = f"{code}.zip"
        local_zip = os.path.join(OUT_DIR, f"{code}.ZIP")
        url = BASE_DIR_URL + server_name

        if not (os.path.exists(local_zip) and zipfile.is_zipfile(local_zip)):
            print(f"Downloading: {code} - {name}")
            _download_with_curl(url, local_zip)
            time.sleep(SLEEP_SECONDS_BETWEEN_DOWNLOADS)
        else:
            print(f"ZIP exists: {code} - {name}")

        dbf_path = _extract_dbf(local_zip, code)
        if not dbf_path:
            print("  No DBF found in ZIP.")
            continue

        raw_csv_path = os.path.join(CSV_DIR, f"{code}.csv")
        processed_csv_path = os.path.join(PROCESSED_DIR, f"{code}.csv")

        dbf_to_csv(dbf_path, raw_csv_path)
        clean_and_filter_csv(raw_csv_path, processed_csv_path)

        print(f"  DBF:  {dbf_path}")
        print(f"  CSV:  {raw_csv_path}")
        print(f"  CSV*: {processed_csv_path}")

    print("Done.")


if __name__ == "__main__":
    main()
