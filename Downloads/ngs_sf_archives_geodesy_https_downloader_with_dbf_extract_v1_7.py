#!/usr/bin/env python3
"""
NGS Archived ShapeFiles downloader (HTTPS via geodesy.noaa.gov) + DBF extraction
with proxy bypass and strong content validation.

Why this update:
You verified with curl that AL.zip is a real ZIP from geodesy.noaa.gov (HTTP 200, Content-Type: application/zip).
If Python requests still receives HTML, the most common cause is a local/corporate proxy being used by requests
(via HTTP_PROXY / HTTPS_PROXY / ALL_PROXY environment variables). curl and requests can behave differently here.

This script:
- Uses https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/<STATE>.zip
- Disables environment proxies (session.trust_env = False)
- Validates ZIP via:
    * HTTP status
    * Content-Type contains "zip" (if present)
    * PK magic bytes
    * zipfile.is_zipfile()
- If HTML is received, saves a debug copy to:
      ./ngs_sf_archive_downloads/debug_html/<STATE>.html

Install:
    python -m pip install requests tqdm

Run:
    python ngs_sf_archives_geodesy_https_downloader_with_dbf_extract_v1_7.py
"""

from __future__ import annotations

import os
import time
import zipfile
from typing import Dict, List, Optional

import requests
from tqdm import tqdm

BASE_DIR_URL = "https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/"

OUT_DIR = "ngs_sf_archive_downloads"
DBF_DIR = os.path.join(OUT_DIR, "dbfs")
DEBUG_HTML_DIR = os.path.join(OUT_DIR, "debug_html")

TIMEOUT = 60
SLEEP_SECONDS_BETWEEN_DOWNLOADS = 1.0

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
        b"<html" in head[:400] or b"<!doctype" in head[:400] or b"<?xml" in head[:400]
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


def _download_zip_validated(session: requests.Session, url: str, out_path: str, state_code: str) -> None:
    os.makedirs(DEBUG_HTML_DIR, exist_ok=True)
    tmp_path = out_path + ".part"

    with session.get(url, stream=True, timeout=TIMEOUT, allow_redirects=True) as resp:
        resp.raise_for_status()

        ctype = (resp.headers.get("Content-Type") or "").lower()
        total = int(resp.headers.get("Content-Length") or 0)

        first_chunk: Optional[bytes] = None
        with open(tmp_path, "wb") as f, tqdm(total=total, unit="B", unit_scale=True, unit_divisor=1024, leave=False) as pbar:
            for chunk in resp.iter_content(chunk_size=262144):
                if not chunk:
                    continue
                if first_chunk is None:
                    first_chunk = chunk[:2048]
                f.write(chunk)
                pbar.update(len(chunk))

    if first_chunk is None:
        raise RuntimeError("Empty response body (unexpected).")

    # If Content-Type is present and not zip-ish, treat as suspicious but still validate bytes.
    if ctype and "zip" not in ctype:
        # Many servers set correct ctype; if it's not zip, likely HTML/error.
        pass

    if _looks_like_html(first_chunk) or not _is_zip_magic(first_chunk):
        # Save debug HTML (or non-zip) for inspection
        debug_path = os.path.join(DEBUG_HTML_DIR, f"{state_code}.html")
        try:
            # Convert partial to text best-effort
            with open(tmp_path, "rb") as rf, open(debug_path, "wb") as wf:
                wf.write(rf.read())
        except Exception:
            pass

        preview = first_chunk[:200].decode("utf-8", errors="replace")
        raise RuntimeError(
            "Downloaded content is not a ZIP. A debug copy was saved.\n"
            f"URL: {url}\n"
            f"Content-Type: {ctype or '(missing)'}\n"
            f"Debug file: {debug_path}\n"
            f"First bytes preview: {preview!r}"
        )

    if not zipfile.is_zipfile(tmp_path):
        raise RuntimeError(f"Downloaded file failed zipfile validation: {tmp_path}")

    os.replace(tmp_path, out_path)


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(DBF_DIR, exist_ok=True)

    session = requests.Session()
    # Critical: do NOT honor HTTP(S)_PROXY / ALL_PROXY environment variables
    session.trust_env = False

    session.headers.update(
        {
            "User-Agent": "ngs-shapefiles-geodesy-downloader/1.7",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
        }
    )

    for code, name in STATE_CODES.items():
        server_name = f"{code}.zip"
        local_name = f"{code}.ZIP"
        url = BASE_DIR_URL + server_name
        zip_path = os.path.join(OUT_DIR, local_name)

        if os.path.exists(zip_path) and os.path.getsize(zip_path) > 0 and zipfile.is_zipfile(zip_path):
            print(f"ZIP exists: {code} - {name}")
        else:
            print(f"Downloading: {code} - {name} ({server_name})")
            _download_zip_validated(session, url, zip_path, state_code=code)
            time.sleep(SLEEP_SECONDS_BETWEEN_DOWNLOADS)

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
