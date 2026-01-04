#!/usr/bin/env python3
"""
NGS Archived ShapeFiles downloader (direct file downloads + DBF extraction)
with ZIP validation and base-URL failover.

Problem addressed:
Some environments/CDNs may return an HTML 404 page with a 200 status code. If you save that response
as "*.zip", the file will start with something like "<?xml ...><html>...404 Error...".

This script:
- Downloads per-state ZIPs from the published directory listing.
- Validates that the downloaded content is actually a ZIP (checks for PK magic bytes).
- If it receives HTML (or other non-ZIP), it automatically retries using an alternate base host.
- Extracts any .dbf files from each ZIP into: ./ngs_sf_archive_downloads/dbfs/
  (prefixed with the state code to avoid collisions)

Base directories (both show the per-state ZIP listings):
- https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/
- https://www.ngs.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/

Install:
    python -m pip install requests tqdm

Run:
    python ngs_sf_archives_direct_downloader_with_dbf_extract_v1_3.py
"""

from __future__ import annotations

import os
import time
import zipfile
from typing import Dict, List, Optional

import requests
from tqdm import tqdm

BASE_DIR_URLS = [
    "https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/",
    "https://www.ngs.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/",
]

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
    return head.startswith(b"<") and (b"<html" in head[:200] or b"<!doctype" in head[:200] or b"<?xml" in head[:200])


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

        with open(tmp_path, "wb") as f, tqdm(total=total, unit="B", unit_scale=True, unit_divisor=1024) as pbar:
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


def _try_download_from_bases(session: requests.Session, code: str, out_path: str) -> str:
    candidates = [f"{code}.zip", f"{code}.ZIP"]
    last_error: Optional[Exception] = None

    for base in BASE_DIR_URLS:
        for name in candidates:
            url = base + name
            try:
                _download_zip_validated(session, url, out_path)
                return url
            except Exception as e:
                last_error = e
                part = out_path + ".part"
                if os.path.exists(part):
                    try:
                        os.remove(part)
                    except OSError:
                        pass
                continue

    raise RuntimeError(f"All base URL attempts failed for {code}. Last error: {last_error}")


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(DBF_DIR, exist_ok=True)

    session = requests.Session()
    session.headers.update(
        {
            "User-Agent": "ngs-shapefiles-direct-downloader/1.3",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        }
    )

    for code, name in STATE_CODES.items():
        zip_path = os.path.join(OUT_DIR, f"{code}.zip")

        if not (os.path.exists(zip_path) and os.path.getsize(zip_path) > 0):
            print(f"Downloading: {code} - {name}")
            used_url = _try_download_from_bases(session, code, zip_path)
            print(f"  source: {used_url}")
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
