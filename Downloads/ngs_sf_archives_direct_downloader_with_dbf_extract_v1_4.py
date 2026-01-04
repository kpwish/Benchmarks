#!/usr/bin/env python3
"""
NGS Archived ShapeFiles downloader (direct ZIP downloads + DBF extraction)

Base directory (authoritative):
    https://www.ngs.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/

Behavior:
- Downloads per-state ZIPs using CAPITALIZED filenames (e.g., AR.ZIP).
- Validates that each download is truly a ZIP (checks PK magic bytes).
- Extracts all .dbf files into:
      ./ngs_sf_archive_downloads/dbfs/
  Prefixes extracted DBFs with the state code to avoid name collisions.

Install:
    python -m pip install requests tqdm

Run:
    python ngs_sf_archives_direct_downloader_with_dbf_extract_v1_4.py
"""

from __future__ import annotations

import os
import time
import zipfile
from typing import Dict, List, Optional

import requests
from tqdm import tqdm

BASE_DIR_URL = "https://www.ngs.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/"

OUT_DIR = "ngs_sf_archive_downloads"
DBF_DIR = os.path.join(OUT_DIR, "dbfs")

TIMEOUT = 60
SLEEP_SECONDS_BETWEEN_DOWNLOADS = 1.0

# 50 states + DC (postal abbreviations)
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


def _is_zip_magic(b: bytes) -> bool:
    return b.startswith(b"PK")


def _looks_like_html(b: bytes) -> bool:
    head = b.lstrip().lower()
    return head.startswith(b"<") and (
        b"<html" in head[:200] or b"<!doctype" in head[:200] or b"<?xml" in head[:200]
    )


def _extract_dbfs(zip_path: str, dbf_dir: str, prefix: str) -> List[str]:
    extracted: List[str] = []
    os.makedirs(dbf_dir, exist_ok=True)

    with zipfile.ZipFile(zip_path, "r") as z:
        dbf_members = [m for m in z.namelist() if m.lower().endswith(".dbf")]
        for member in dbf_members:
            base = os.path.basename(member)
            if not base:
                continue

            out_name = f"{prefix}_{base}"
            out_path = os.path.join(dbf_dir, out_name)

            if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
                extracted.append(out_path)
                continue

            with z.open(member) as src, open(out_path, "wb") as dst:
                dst.write(src.read())

            extracted.append(out_path)

    return extracted


def _download_zip_validated(session: requests.Session, url: str, out_path: str) -> None:
    tmp_path = out_path + ".part"

    with session.get(url, stream=True, timeout=TIMEOUT, allow_redirects=True) as resp:
        resp.raise_for_status()

        total = int(resp.headers.get("Content-Length") or 0)
        first_chunk: Optional[bytes] = None

        with open(tmp_path, "wb") as f, tqdm(
            total=total, unit="B", unit_scale=True, unit_divisor=1024
        ) as pbar:
            for chunk in resp.iter_content(chunk_size=262144):
                if not chunk:
                    continue
                if first_chunk is None:
                    first_chunk = chunk[:512]
                f.write(chunk)
                pbar.update(len(chunk))

    if first_chunk is None:
        raise RuntimeError("Empty response body (unexpected).")

    if not _is_zip_magic(first_chunk):
        preview = first_chunk[:200].decode("utf-8", errors="replace")
        if _looks_like_html(first_chunk):
            raise RuntimeError(
                "Downloaded content is HTML, not a ZIP (likely a 404 page).\n"
                f"URL: {url}\n"
                f"First bytes preview: {preview!r}"
            )
        raise RuntimeError(
            "Downloaded content does not look like a ZIP (missing PK signature).\n"
            f"URL: {url}\n"
            f"First bytes preview: {preview!r}"
        )

    os.replace(tmp_path, out_path)


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(DBF_DIR, exist_ok=True)

    session = requests.Session()
    session.headers.update(
        {
            "User-Agent": "ngs-shapefiles-direct-downloader/1.4",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        }
    )

    for code, name in STATE_CODES.items():
        zip_name = f"{code}.ZIP"
        zip_path = os.path.join(OUT_DIR, zip_name)
        url = BASE_DIR_URL + zip_name

        if not (os.path.exists(zip_path) and os.path.getsize(zip_path) > 0):
            print(f"Downloading: {code} - {name}")
            _download_zip_validated(session, url, zip_path)
            time.sleep(SLEEP_SECONDS_BETWEEN_DOWNLOADS)
        else:
            print(f"ZIP exists: {code} - {name}")

        try:
            extracted = _extract_dbfs(zip_path, DBF_DIR, prefix=code)
            if extracted:
                print(f"  Extracted {len(extracted)} DBF file(s) -> {DBF_DIR}")
            else:
                print("  No DBF files found in ZIP.")
        except zipfile.BadZipFile:
            print(f"  ERROR: Bad ZIP file: {zip_path}")
        except Exception as e:
            print(f"  ERROR extracting DBFs from {zip_path}: {e}")

    print("Done.")


if __name__ == "__main__":
    main()
