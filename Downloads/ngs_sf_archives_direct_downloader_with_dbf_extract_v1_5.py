#!/usr/bin/env python3
"""
NGS Archived ShapeFiles downloader (ZIP downloads + DBF extraction) with robust URL fallbacks.

You encountered HTML "404 Error" pages being returned when requesting, for example:
    https://www.ngs.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/AL.ZIP

Even though the directory index shows AL.ZIP is present, some edge/CDN paths can still return
an HTML error document (sometimes with HTTP 200). This script treats that as a failed download
and automatically tries alternate hosts and filename casing.

Bases tried (in order):
  1) https://www.ngs.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/
  2) https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/
  3) https://nweb.ngs.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/

Filenames tried (in order):
  - <STATE>.ZIP
  - <STATE>.zip

Output:
  ZIPs:  ./ngs_sf_archive_downloads/<STATE>.ZIP   (saved with .ZIP extension)
  DBFs:  ./ngs_sf_archive_downloads/dbfs/<STATE>_<dbf_filename>.dbf

Install:
    python -m pip install requests tqdm

Run:
    python ngs_sf_archives_direct_downloader_with_dbf_extract_v1_5.py
"""

from __future__ import annotations

import os
import time
import zipfile
from typing import Dict, List, Optional, Tuple

import requests
from tqdm import tqdm

BASE_DIR_URLS = [
    "https://www.ngs.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/",
    "https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/",
    "https://nweb.ngs.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/",
]

OUT_DIR = "ngs_sf_archive_downloads"
DBF_DIR = os.path.join(OUT_DIR, "dbfs")

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
        b"<html" in head[:300] or b"<!doctype" in head[:300] or b"<?xml" in head[:300]
    )


def _extract_dbfs(zip_path: str, dbf_dir: str, prefix: str) -> int:
    os.makedirs(dbf_dir, exist_ok=True)
    count = 0

    with zipfile.ZipFile(zip_path, "r") as z:
        dbf_members = [m for m in z.namelist() if m.lower().endswith(".dbf")]
        for member in dbf_members:
            base = os.path.basename(member)
            if not base:
                continue

            out_name = f"{prefix}_{base}"
            out_path = os.path.join(dbf_dir, out_name)

            if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
                count += 1
                continue

            with z.open(member) as src, open(out_path, "wb") as dst:
                dst.write(src.read())
            count += 1

    return count


def _download_zip_validated(session: requests.Session, url: str, out_path: str) -> None:
    tmp_path = out_path + ".part"

    with session.get(url, stream=True, timeout=TIMEOUT, allow_redirects=True) as resp:
        # If server returns a true HTTP error, stop early.
        if resp.status_code >= 400:
            raise RuntimeError(f"HTTP {resp.status_code} for {url}")

        total = int(resp.headers.get("Content-Length") or 0)
        first_chunk: Optional[bytes] = None

        with open(tmp_path, "wb") as f, tqdm(
            total=total, unit="B", unit_scale=True, unit_divisor=1024, leave=False
        ) as pbar:
            for chunk in resp.iter_content(chunk_size=262144):
                if not chunk:
                    continue
                if first_chunk is None:
                    first_chunk = chunk[:1024]
                f.write(chunk)
                pbar.update(len(chunk))

    if first_chunk is None:
        raise RuntimeError(f"Empty response body for {url}")

    if not _is_zip_magic(first_chunk):
        preview = first_chunk[:200].decode("utf-8", errors="replace")
        if _looks_like_html(first_chunk):
            raise RuntimeError(
                f"HTML received instead of ZIP for {url}. First bytes: {preview!r}"
            )
        raise RuntimeError(
            f"Non-ZIP content received for {url}. First bytes: {preview!r}"
        )

    os.replace(tmp_path, out_path)


def _try_download(session: requests.Session, code: str, out_path: str) -> Tuple[str, str]:
    # Keep output filenames capitalized (.ZIP) as requested, but try both casings on the server.
    server_names = [f"{code}.ZIP", f"{code}.zip"]

    last_error: Optional[Exception] = None
    for base in BASE_DIR_URLS:
        for name in server_names:
            url = base + name
            try:
                _download_zip_validated(session, url, out_path)
                return base, name
            except Exception as e:
                last_error = e
                part = out_path + ".part"
                if os.path.exists(part):
                    try:
                        os.remove(part)
                    except OSError:
                        pass
                continue

    raise RuntimeError(f"All URL attempts failed for {code}. Last error: {last_error}")


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(DBF_DIR, exist_ok=True)

    session = requests.Session()
    session.headers.update(
        {
            "User-Agent": "ngs-shapefiles-direct-downloader/1.5",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        }
    )

    for code, name in STATE_CODES.items():
        zip_path = os.path.join(OUT_DIR, f"{code}.ZIP")

        if not (os.path.exists(zip_path) and os.path.getsize(zip_path) > 0):
            print(f"Downloading: {code} - {name}")
            used_base, used_name = _try_download(session, code, zip_path)
            print(f"  source: {used_base}{used_name}")
            time.sleep(SLEEP_SECONDS_BETWEEN_DOWNLOADS)
        else:
            print(f"ZIP exists: {code} - {name}")

        try:
            n_dbfs = _extract_dbfs(zip_path, DBF_DIR, prefix=code)
            if n_dbfs:
                print(f"  Extracted {n_dbfs} DBF file(s) -> {DBF_DIR}")
            else:
                print("  No DBF files found in ZIP.")
        except zipfile.BadZipFile:
            print(f"  ERROR: Bad ZIP file: {zip_path}")
        except Exception as e:
            print(f"  ERROR extracting DBFs from {zip_path}: {e}")

    print("Done.")


if __name__ == "__main__":
    main()
