#!/usr/bin/env python3
"""
NGS Archived ShapeFiles downloader (direct file downloads)

Instead of scraping /cgi-bin/sf_archive.prl (which frequently changes markup/parameters),
this script downloads the already-generated monthly ZIPs directly from NOAA's archive:

    https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/

That directory publishes per-state ZIPs (e.g., AR.zip / AR.ZIP) and many other regions. citeturn2search0

Install:
    python -m pip install requests tqdm

Run:
    python ngs_sf_archives_direct_downloader.py

Output:
    ./ngs_sf_archive_downloads/<STATE>.zip
"""

from __future__ import annotations

import os
import time
from typing import Dict

import requests
from tqdm import tqdm

BASE_DIR_URL = "https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/"
OUT_DIR = "ngs_sf_archive_downloads"

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
    # Stream download with progress bar.
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
    """The directory lists both .zip and .ZIP for many entries; try both."""
    # Prefer lowercase .zip (commonly present), then uppercase.
    candidates = [f"{code}.zip", f"{code}.ZIP"]
    for name in candidates:
        url = BASE_DIR_URL + name
        try:
            r = session.head(url, timeout=TIMEOUT, allow_redirects=True)
            if r.status_code == 200:
                return url
        except requests.RequestException:
            # Fall through to next candidate
            pass
    # If HEAD is blocked, attempt GET range-less as a fallback (cheap-ish, but still a request).
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


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)

    session = requests.Session()
    session.headers.update(
        {
            "User-Agent": "ngs-shapefiles-direct-downloader/1.0",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        }
    )

    for code, name in STATE_CODES.items():
        out_path = os.path.join(OUT_DIR, f"{code}.zip")
        if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
            print(f"Skipping (exists): {code} - {name}")
            continue

        print(f"Downloading: {code} - {name}")
        url = _pick_existing_url(session, code)
        _download_file(session, url, out_path)
        time.sleep(SLEEP_SECONDS_BETWEEN_DOWNLOADS)

    print("Done.")


if __name__ == "__main__":
    main()
