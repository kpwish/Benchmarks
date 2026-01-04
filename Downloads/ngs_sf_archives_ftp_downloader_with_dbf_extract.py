#!/usr/bin/env python3
"""
NGS Archived ShapeFiles downloader (FTP) + DBF extraction

Drop-in replacement for the HTTPS-based downloader.

Why FTP:
NOAA's DS_ARCHIVE is designed for FTP access. Some HTTPS/CDN paths can return HTML error
documents in place of ZIP content. FTP avoids that failure mode.

FTP host and directory:
  ftp.ngs.noaa.gov
  /pub/DS_ARCHIVE/ShapeFiles/

Behavior:
- Downloads per-state ZIPs as CAPITALIZED filenames (e.g., AL.ZIP) into:
    ./ngs_sf_archive_downloads/
- Extracts any .dbf files from each ZIP into:
    ./ngs_sf_archive_downloads/dbfs/
  (prefixed with the state code to avoid collisions)

Dependencies:
- Python standard library only (ftplib, zipfile, etc.)

Run:
  python ngs_sf_archives_ftp_downloader_with_dbf_extract.py
"""

from __future__ import annotations

import os
import socket
import time
import zipfile
from ftplib import FTP, error_perm
from typing import Dict, Optional

FTP_HOST = "ftp.ngs.noaa.gov"
FTP_DIR = "/pub/DS_ARCHIVE/ShapeFiles"

OUT_DIR = "ngs_sf_archive_downloads"
DBF_DIR = os.path.join(OUT_DIR, "dbfs")

# Network behavior
CONNECT_TIMEOUT = 30
RETR_TIMEOUT = 120
MAX_RETRIES_PER_FILE = 4
SLEEP_SECONDS_BETWEEN_DOWNLOADS = 0.5

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


def _ensure_dirs() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(DBF_DIR, exist_ok=True)


def _connect_ftp() -> FTP:
    # Configure socket default timeout for connect + data transfers
    socket.setdefaulttimeout(RETR_TIMEOUT)
    ftp = FTP(timeout=CONNECT_TIMEOUT)
    ftp.connect(FTP_HOST)
    ftp.login()  # anonymous
    ftp.cwd(FTP_DIR)
    return ftp


def _ftp_file_size(ftp: FTP, remote_name: str) -> Optional[int]:
    try:
        return ftp.size(remote_name)
    except Exception:
        return None


def _download_one(ftp: FTP, remote_name: str, local_path: str) -> None:
    """Download remote_name to local_path using binary mode."""
    tmp_path = local_path + ".part"
    total = _ftp_file_size(ftp, remote_name)  # may be None

    downloaded = 0
    last_print = 0.0

    def _write_chunk(chunk: bytes) -> None:
        nonlocal downloaded, last_print
        f.write(chunk)
        downloaded += len(chunk)
        now = time.time()
        # Print progress at most ~2x/sec
        if now - last_print >= 0.5:
            if total and total > 0:
                pct = (downloaded / total) * 100.0
                print(f"    {downloaded:,} / {total:,} bytes ({pct:0.1f}%)", end="\r")
            else:
                print(f"    {downloaded:,} bytes", end="\r")
            last_print = now

    with open(tmp_path, "wb") as f:
        ftp.retrbinary(f"RETR {remote_name}", _write_chunk, blocksize=1024 * 64)

    print()  # newline after progress

    # Basic ZIP validity check before moving into place
    if not zipfile.is_zipfile(tmp_path):
        # Keep the partial for inspection but raise
        raise RuntimeError(f"Downloaded file is not a valid ZIP: {tmp_path}")

    os.replace(tmp_path, local_path)


def _extract_dbfs(zip_path: str, prefix: str) -> int:
    """Extract all .dbf files from zip_path into DBF_DIR, prefixing with state code."""
    count = 0
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
                count += 1
                continue

            with z.open(member) as src, open(out_path, "wb") as dst:
                dst.write(src.read())
            count += 1
    return count


def _remote_name_for_state(code: str) -> str:
    # NOAA directory typically uses .ZIP for these artifacts.
    return f"{code}.ZIP"


def main() -> None:
    _ensure_dirs()

    # One FTP connection for the whole session (fast). If it drops, we reconnect.
    ftp: Optional[FTP] = None

    for code, name in STATE_CODES.items():
        remote_name = _remote_name_for_state(code)
        local_zip = os.path.join(OUT_DIR, remote_name)

        if os.path.exists(local_zip) and os.path.getsize(local_zip) > 0 and zipfile.is_zipfile(local_zip):
            print(f"ZIP exists: {code} - {name}")
        else:
            print(f"Downloading: {code} - {name} ({remote_name})")

            # Retry loop with reconnects
            last_err: Optional[Exception] = None
            for attempt in range(1, MAX_RETRIES_PER_FILE + 1):
                try:
                    if ftp is None:
                        ftp = _connect_ftp()

                    _download_one(ftp, remote_name, local_zip)
                    last_err = None
                    break

                except error_perm as e:
                    # Permanent FTP error (e.g., 550 file not found)
                    last_err = e
                    raise RuntimeError(f"FTP permission/error for {remote_name}: {e}") from e

                except Exception as e:
                    last_err = e
                    print(f"  Attempt {attempt}/{MAX_RETRIES_PER_FILE} failed: {e}")
                    # Clean up partial file if present
                    part = local_zip + ".part"
                    if os.path.exists(part):
                        try:
                            os.remove(part)
                        except OSError:
                            pass
                    # Reconnect next attempt
                    try:
                        if ftp is not None:
                            ftp.quit()
                    except Exception:
                        pass
                    ftp = None
                    time.sleep(1.0 * attempt)

            if last_err is not None:
                raise RuntimeError(f"Failed to download {remote_name} after retries. Last error: {last_err}")

            time.sleep(SLEEP_SECONDS_BETWEEN_DOWNLOADS)

        # Extract DBFs
        try:
            n_dbfs = _extract_dbfs(local_zip, prefix=code)
            if n_dbfs:
                print(f"  Extracted {n_dbfs} DBF file(s) -> {DBF_DIR}")
            else:
                print("  No DBF files found in ZIP.")
        except zipfile.BadZipFile:
            print(f"  ERROR: Bad ZIP file: {local_zip}")
        except Exception as e:
            print(f"  ERROR extracting DBFs from {local_zip}: {e}")

    # Close FTP connection cleanly
    if ftp is not None:
        try:
            ftp.quit()
        except Exception:
            pass

    print("Done.")


if __name__ == "__main__":
    main()
