#!/usr/bin/env python3
"""
NGS Archived ShapeFiles downloader (direct file downloads + DBF extraction)

Downloads per-state ZIPs directly from NOAA's archive directory:
    https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/

Then extracts any .dbf files from each ZIP into:
    ./ngs_sf_archive_downloads/dbfs/

Install:
    python -m pip install requests tqdm

Run:
    python ngs_sf_archives_direct_downloader_with_dbf_extract.py
"""

from __future__ import annotations

import os
import time
import zipfile
from typing import Dict, List

import requests
from tqdm import tqdm

BASE_DIR_URL = "https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/"
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


def _download_file(session: requests.Session, url: str, out_path: str) -> None:
    """Stream download to disk with a progress bar."""
    with session.get(url, stream=True, timeout=TIMEOUT) as resp:
        resp.raise_for_status()
        total = int(resp.headers.get("Content-Length") or 0)

        tmp_path = out_path + ".part"
        with open(tmp_path, "wb") as f, tqdm(total=total, unit="B", unit_scale=True, unit_divisor=1024) as pbar:
            for chunk in resp.iter_content(chunk_size=262144):
                if not chunk:
                    continue
                f.write(chunk)
                pbar.update(len(chunk))

        os.replace(tmp_path, out_path)


def _pick_existing_url(session: requests.Session, code: str) -> str:
    """Try both .zip and .ZIP (the directory may contain either)."""
    candidates = [f"{code}.zip", f"{code}.ZIP"]
    for name in candidates:
        url = BASE_DIR_URL + name
        try:
            r = session.head(url, timeout=TIMEOUT, allow_redirects=True)
            if r.status_code == 200:
                return url
        except requests.RequestException:
            pass

    # Fallback if HEAD is blocked
    for name in candidates:
        url = BASE_DIR_URL + name
        try:
            r = session.get(url, timeout=TIMEOUT, stream=True)
            if r.status_code == 200:
                r.close()
                return url
            r.close()
        except requests.RequestException:
            pass

    raise RuntimeError(f"Could not find {code}.zip (or .ZIP) under {BASE_DIR_URL}")


def _extract_dbfs(zip_path: str, dbf_dir: str, prefix: str) -> List[str]:
    """Extract all .dbf files from zip_path into dbf_dir.

    Extracted filenames are prefixed with the state code to avoid collisions.
    Returns a list of extracted file paths.
    """
    extracted: List[str] = []
    os.makedirs(dbf_dir, exist_ok=True)

    with zipfile.ZipFile(zip_path, "r") as z:
        dbf_members = [m for m in z.namelist() if m.lower().endswith(".dbf")]
        for member in dbf_members:
            base = os.path.basename(member)
            if not base:
                continue

            # Prefix with state code to avoid overwriting similarly named DBFs
            out_name = f"{prefix}_{base}"
            out_path = os.path.join(dbf_dir, out_name)

            # If already extracted and non-empty, skip
            if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
                extracted.append(out_path)
                continue

            with z.open(member) as src, open(out_path, "wb") as dst:
                dst.write(src.read())

            extracted.append(out_path)

    return extracted


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(DBF_DIR, exist_ok=True)

    session = requests.Session()
    session.headers.update(
        {
            "User-Agent": "ngs-shapefiles-direct-downloader/1.1",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        }
    )

    for code, name in STATE_CODES.items():
        zip_path = os.path.join(OUT_DIR, f"{code}.zip")

        # Download ZIP if missing
        if not (os.path.exists(zip_path) and os.path.getsize(zip_path) > 0):
            print(f"Downloading: {code} - {name}")
            url = _pick_existing_url(session, code)
            _download_file(session, url, zip_path)
            time.sleep(SLEEP_SECONDS_BETWEEN_DOWNLOADS)
        else:
            print(f"ZIP exists: {code} - {name}")

        # Extract DBFs
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
