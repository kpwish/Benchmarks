#!/usr/bin/env python3
"""
NGS ShapeFiles downloader using system curl + DBF extraction + CSV conversion + CSV cleanup/filtering

Pipeline:
1) Download https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/<STATE>.zip using system curl
2) Save ZIP locally as:        ./ngs_sf_archive_downloads/<STATE>.ZIP
3) Extract DBF to:             ./ngs_sf_archive_downloads/dbfs/<STATE>.dbf
4) Convert DBF to raw CSV:     ./ngs_sf_archive_downloads/csvs/<STATE>.csv
5) Clean/filter to CSV:        ./ngs_sf_archive_downloads/csvs/Processed/pois_<STATE>_<DATA_DATE>.csv

Processed CSV filename rule:
- <DATA_DATE> is taken from the first non-empty value of the `data_date` column
- Non-numeric characters are stripped (YYYYMMDD)
- If data_date is missing or empty, filename falls back to pois_<STATE>_UNKNOWN.csv

Fields kept (case-insensitive, in this exact order):
data_date,data_srce,pid,name,dec_lat,dec_lon,state,county,marker,setting,last_recv,last_cond,last_recby,ortho_ht
"""

from __future__ import annotations

import csv
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
    "AL": "Alabama","AK": "Alaska","AZ": "Arizona","AR": "Arkansas","CA": "California",
    "CO": "Colorado","CT": "Connecticut","DE": "Delaware","DC": "District of Columbia",
    "FL": "Florida","GA": "Georgia","HI": "Hawaii","ID": "Idaho","IL": "Illinois",
    "IN": "Indiana","IA": "Iowa","KS": "Kansas","KY": "Kentucky","LA": "Louisiana",
    "ME": "Maine","MD": "Maryland","MA": "Massachusetts","MI": "Michigan",
    "MN": "Minnesota","MS": "Mississippi","MO": "Missouri","MT": "Montana",
    "NE": "Nebraska","NV": "Nevada","NH": "New Hampshire","NJ": "New Jersey",
    "NM": "New Mexico","NY": "New York","NC": "North Carolina","ND": "North Dakota",
    "OH": "Ohio","OK": "Oklahoma","OR": "Oregon","PA": "Pennsylvania","RI": "Rhode Island",
    "SC": "South Carolina","SD": "South Dakota","TN": "Tennessee","TX": "Texas",
    "UT": "Utah","VT": "Vermont","VA": "Virginia","WA": "Washington",
    "WV": "West Virginia","WI": "Wisconsin","WY": "Wyoming"
}

RELEVANT_FIELDS: List[str] = [
    "data_date","data_srce","pid","name","dec_lat","dec_lon","state","county",
    "marker","setting","last_recv","last_cond","last_recby","ortho_ht"
]

_WS_RE = re.compile(r"\s+")


def _ensure_dirs() -> None:
    os.makedirs(DBF_DIR, exist_ok=True)
    os.makedirs(CSV_DIR, exist_ok=True)
    os.makedirs(PROCESSED_DIR, exist_ok=True)


def _download_with_curl(url: str, out_path: str) -> None:
    tmp_path = out_path + ".part"
    subprocess.run([
        "curl","-fL","--retry","5","--retry-delay","1",
        "--connect-timeout","20","--max-time","300",
        "-o", tmp_path, url
    ], check=True)
    if not zipfile.is_zipfile(tmp_path):
        raise RuntimeError("Downloaded file is not a valid ZIP")
    os.replace(tmp_path, out_path)


def _extract_dbf(zip_path: str, state_code: str) -> str | None:
    out_path = os.path.join(DBF_DIR, f"{state_code}.dbf")
    if os.path.exists(out_path):
        return out_path
    with zipfile.ZipFile(zip_path,"r") as z:
        for n in z.namelist():
            if n.lower().endswith(".dbf"):
                with z.open(n) as src, open(out_path,"wb") as dst:
                    dst.write(src.read())
                return out_path
    return None


def _parse_dbf_header_and_fields(f) -> Tuple[int,int,List[Tuple[str,str,int,int]]]:
    h = f.read(32)
    nrec = struct.unpack("<I",h[4:8])[0]
    hlen = struct.unpack("<H",h[8:10])[0]
    rlen = struct.unpack("<H",h[10:12])[0]
    fields = []
    while True:
        d = f.read(32)
        if d[0] == 0x0D:
            break
        fields.append((
            d[0:11].split(b"\x00",1)[0].decode("ascii","ignore").strip(),
            chr(d[11]), d[16], d[17]
        ))
    f.seek(hlen)
    return nrec,rlen,fields


def dbf_to_csv(dbf: str, csv_out: str) -> None:
    with open(dbf,"rb") as f:
        nrec,rlen,fields = _parse_dbf_header_and_fields(f)
        headers = [n for n,_,_,_ in fields]
        with open(csv_out,"w",newline="",encoding="utf-8") as o:
            w = csv.DictWriter(o,fieldnames=headers)
            w.writeheader()
            for _ in range(nrec):
                rec = f.read(rlen)
                if rec[0:1] == b"*":
                    continue
                row,off = {},1
                for n,t,l,d in fields:
                    row[n] = rec[off:off+l].decode("latin-1","ignore").strip()
                    off += l
                w.writerow(row)


def clean_and_filter_csv(raw_csv: str, state: str) -> None:
    with open(raw_csv,"r",encoding="utf-8") as f:
        r = csv.DictReader(f)
        header_map = {h.lower():h for h in r.fieldnames or []}
        out_headers = [header_map[h.lower()] for h in RELEVANT_FIELDS if h.lower() in header_map]
        rows = []
        data_date = None
        for row in r:
            cleaned = {}
            for h in out_headers:
                v = str(row.get(h,"")).replace('"',"").strip()
                cleaned[h] = _WS_RE.sub(" ", v)
            if not data_date:
                dd = cleaned.get(header_map.get("data_date",""),"")
                if dd:
                    data_date = re.sub(r"[^0-9]","",dd)
            rows.append(cleaned)
    if not data_date:
        data_date = "UNKNOWN"
    out = os.path.join(PROCESSED_DIR, f"pois_{state}_{data_date}.csv")
    with open(out,"w",newline="",encoding="utf-8") as o:
        w = csv.DictWriter(o,fieldnames=out_headers)
        w.writeheader()
        w.writerows(rows)


def main() -> None:
    _ensure_dirs()
    for state in STATE_CODES:
        zipf = os.path.join(OUT_DIR, f"{state}.ZIP")
        if not os.path.exists(zipf):
            _download_with_curl(BASE_DIR_URL + f"{state}.zip", zipf)
        dbf = _extract_dbf(zipf,state)
        if not dbf:
            continue
        raw = os.path.join(CSV_DIR, f"{state}.csv")
        dbf_to_csv(dbf, raw)
        clean_and_filter_csv(raw, state)
    print("Done.")


if __name__ == "__main__":
    main()
