#!/usr/bin/env python3
"""
NGS ShapeFiles downloader using system curl (workaround for Python HTTPS 404)

You validated that:
    curl -L -o /tmp/AL.zip https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/AL.zip
returns a real ZIP.

However, Python `requests` in your environment is receiving an HTML 404 page that includes
/ngsstandard/... assets, indicating it is being routed to a different NGS web front-end
than curl is hitting (often due to network/security middleware differences).

This script uses the system `curl` binary for downloads (same behavior as your successful test),
then extracts DBFs.

Behavior:
- Downloads https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/<STATE>.zip
- Saves locally as ./ngs_sf_archive_downloads/<STATE>.ZIP
- Verifies ZIP via zipfile.is_zipfile()
- Extracts .dbf files into ./ngs_sf_archive_downloads/dbfs/ as <STATE>_<name>.dbf

Requirements:
- macOS: curl is preinstalled
- Python stdlib only

Run:
  python ngs_sf_archives_curl_downloader_with_dbf_extract_v1_8.py
"""

from __future__ import annotations

import os
import subprocess
import time
import zipfile
from typing import Dict, List

BASE_DIR_URL = "https://geodesy.noaa.gov/pub/DS_ARCHIVE/ShapeFiles/"

OUT_DIR = "ngs_sf_archive_downloads"
DBF_DIR = os.path.join(OUT_DIR, "dbfs")

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


def _ensure_dirs() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(DBF_DIR, exist_ok=True)


def _download_with_curl(url: str, out_path: str) -> None:
    """Download url to out_path using curl, following redirects."""
    tmp_path = out_path + ".part"

    # -f: fail on HTTP errors (non-2xx/3xx)
    # -L: follow redirects
    # --retry: transient network robustness
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
    except FileNotFoundError as e:
        raise RuntimeError("curl is not installed or not on PATH.") from e
    except subprocess.CalledProcessError as e:
        stderr = (e.stderr or "").strip()
        stdout = (e.stdout or "").strip()
        raise RuntimeError(f"curl failed for {url}.\nSTDOUT: {stdout}\nSTDERR: {stderr}") from e

    # Validate ZIP before finalizing
    if not zipfile.is_zipfile(tmp_path):
        # Keep the artifact for inspection
        raise RuntimeError(f"Downloaded file is not a valid ZIP: {tmp_path} (from {url})")

    os.replace(tmp_path, out_path)


def _extract_dbfs(zip_path: str, prefix: str) -> List[str]:
    extracted: List[str] = []
    with zipfile.ZipFile(zip_path, "r") as z:
        for member in z.namelist():
            if not member.lower().endswith(".dbf"):
                continue
            base = os.path.basename(member)
            if not base:
                continue
            out_name = f"{prefix}_{base}"
            out_path = os.path.join(DBF_DIR, out_name)

            if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
                extracted.append(out_path)
                continue

            with z.open(member) as src, open(out_path, "wb") as dst:
                dst.write(src.read())
            extracted.append(out_path)
    return extracted


def main() -> None:
    _ensure_dirs()

    for code, name in STATE_CODES.items():
        server_name = f"{code}.zip"
        local_name = f"{code}.ZIP"
        url = BASE_DIR_URL + server_name
        zip_path = os.path.join(OUT_DIR, local_name)

        if os.path.exists(zip_path) and os.path.getsize(zip_path) > 0 and zipfile.is_zipfile(zip_path):
            print(f"ZIP exists: {code} - {name}")
        else:
            print(f"Downloading: {code} - {name} ({server_name})")
            _download_with_curl(url, zip_path)
            time.sleep(SLEEP_SECONDS_BETWEEN_DOWNLOADS)

        extracted = _extract_dbfs(zip_path, prefix=code)
        if extracted:
            print(f"  Extracted {len(extracted)} DBF file(s) -> {DBF_DIR}")
        else:
            print("  No DBF files found in ZIP.")

    print("Done.")


if __name__ == "__main__":
    main()
