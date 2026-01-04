#!/usr/bin/env python3
"""
NGS Archived ShapeFiles downloader (robust, self-configuring)

Target page:
    https://geodesy.noaa.gov/cgi-bin/sf_archive.prl

Why this version:
- NOAA's page markup changes (sometimes a <select>, sometimes a button grid, sometimes minimal HTML),
  which makes HTML-parsing brittle.
- This script auto-discovers the correct request parameters by probing the endpoint with a small
  set of likely parameter names/values and validating the response as a ZIP.

Install:
    python -m pip install requests tqdm beautifulsoup4

Run:
    python ngs_sf_archive_downloader_v1_2.py

Notes:
- Default downloads: 50 US states + DC
- Add territories/other regions by extending REGIONS if desired.
"""

from __future__ import annotations

import os
import re
import time
from dataclasses import dataclass
from typing import Optional, Tuple

import requests
from bs4 import BeautifulSoup
from tqdm import tqdm

FORM_URL = "https://geodesy.noaa.gov/cgi-bin/sf_archive.prl"
OUT_DIR = "ngs_sf_archive_downloads"
TIMEOUT = 60
SLEEP_SECONDS_BETWEEN_DOWNLOADS = 1.0

# 50 states + DC
REGIONS = [
    "ALABAMA","ALASKA","ARIZONA","ARKANSAS","CALIFORNIA","COLORADO","CONNECTICUT","DELAWARE",
    "DISTRICT OF COLUMBIA","FLORIDA","GEORGIA","HAWAII","IDAHO","ILLINOIS","INDIANA","IOWA","KANSAS",
    "KENTUCKY","LOUISIANA","MAINE","MARYLAND","MASSACHUSETTS","MICHIGAN","MINNESOTA","MISSISSIPPI",
    "MISSOURI","MONTANA","NEBRASKA","NEVADA","NEW HAMPSHIRE","NEW JERSEY","NEW MEXICO","NEW YORK",
    "NORTH CAROLINA","NORTH DAKOTA","OHIO","OKLAHOMA","OREGON","PENNSYLVANIA","RHODE ISLAND",
    "SOUTH CAROLINA","SOUTH DAKOTA","TENNESSEE","TEXAS","UTAH","VERMONT","VIRGINIA","WASHINGTON",
    "WEST VIRGINIA","WISCONSIN","WYOMING"
]

# Candidate parameter names for the region/state.
CANDIDATE_STATE_PARAM_NAMES = [
    "State", "STATE", "state",
    "st", "ST",
    "region", "REGION",
    "area", "AREA",
]

# Candidate ways the server might be told to send ZIP.
CANDIDATE_ZIP_CONTROLS: list[Tuple[str, str]] = [
    ("zip", "zip"),
    ("ZIP", "ZIP"),
    ("compression", "zip"),
    ("Compression", "zip"),
    ("compress", "zip"),
    ("COMPRESS", "ZIP"),
    ("format", "zip"),
    ("FORMAT", "ZIP"),
    ("zip", "Send me all the ShapeFiles compressed into one ZIP file"),
    ("submit", "ZIP"),
]

# Try both POST and GET; many NOAA CGI forms accept either.
METHODS_TO_TRY = ["POST", "GET"]


@dataclass
class EndpointSpec:
    action_url: str
    method: str
    hidden_fields: dict[str, str]
    state_param: str
    zip_param: Optional[Tuple[str, str]]  # (name, value) or None


def safe_filename(name: str) -> str:
    name = re.sub(r"[^\w\-. ]+", "_", name).strip()
    return re.sub(r"\s+", "_", name)


def _is_zip_response(resp: requests.Response, first_chunk: bytes) -> bool:
    cd = resp.headers.get("Content-Disposition", "")
    ctype = (resp.headers.get("Content-Type", "") or "").lower()
    if "zip" in ctype:
        return True
    if "filename=" in cd.lower() and ("\.zip" in cd.lower() or "zip" in cd.lower()):
        return True
    if first_chunk.startswith(b"PK"):
        return True
    return False


def _request(session: requests.Session, url: str, method: str, payload: dict[str, str], stream: bool = True) -> requests.Response:
    if method.upper() == "POST":
        return session.post(url, data=payload, stream=stream, timeout=TIMEOUT)
    return session.get(url, params=payload, stream=stream, timeout=TIMEOUT)


def _parse_action_and_hidden(html: str, base_url: str) -> tuple[str, dict[str, str]]:
    """Best-effort: if a <form> exists, capture action and hidden fields; otherwise fall back."""
    soup = BeautifulSoup(html, "html.parser")
    form = soup.find("form")
    action_url = base_url
    hidden: dict[str, str] = {}

    if form:
        action = form.get("action") or base_url
        from urllib.parse import urljoin
        action_url = urljoin(base_url, action)

        for inp in form.select("input[type=hidden], input[type=HIDDEN]"):
            name = inp.get("name")
            if name:
                hidden[name] = inp.get("value", "")

    return action_url, hidden


def discover_endpoint_spec(session: requests.Session, base_url: str) -> EndpointSpec:
    """Auto-discover working parameters by probing the endpoint and validating a ZIP response."""
    r = session.get(base_url, timeout=TIMEOUT)
    r.raise_for_status()

    action_url, hidden_fields = _parse_action_and_hidden(r.text, base_url)
    probe_region = "ARKANSAS"

    for method in METHODS_TO_TRY:
        for state_param in CANDIDATE_STATE_PARAM_NAMES:
            for zip_control in [None] + CANDIDATE_ZIP_CONTROLS:
                payload = dict(hidden_fields)
                payload[state_param] = probe_region
                if zip_control:
                    zname, zval = zip_control
                    payload[zname] = zval

                try:
                    resp = _request(session, action_url, method, payload, stream=True)
                    resp.raise_for_status()
                    it = resp.iter_content(chunk_size=4096)
                    first = next(it, b"")
                    ok = _is_zip_response(resp, first)
                    resp.close()
                    if ok:
                        return EndpointSpec(
                            action_url=action_url,
                            method=method,
                            hidden_fields=hidden_fields,
                            state_param=state_param,
                            zip_param=zip_control,
                        )
                except requests.RequestException:
                    continue

    debug_path = os.path.join(OUT_DIR, "_debug_sf_archive_page.html")
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(debug_path, "w", encoding="utf-8") as f:
        f.write(r.text)

    raise RuntimeError(
        "Could not auto-discover a working request pattern for the NGS archive endpoint.\n"
        f"A debug copy of the page HTML was saved to: {debug_path}\n"
        "Open that file and search for CGI parameter names (form/input elements), then extend the candidate lists."
    )


def download_region(session: requests.Session, spec: EndpointSpec, region: str, out_dir: str) -> str:
    payload = dict(spec.hidden_fields)
    payload[spec.state_param] = region
    if spec.zip_param:
        zname, zval = spec.zip_param
        payload[zname] = zval

    out_path = os.path.join(out_dir, f"{safe_filename(region)}.zip")
    if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
        return out_path

    resp = _request(session, spec.action_url, spec.method, payload, stream=True)
    resp.raise_for_status()

    cd = resp.headers.get("Content-Disposition", "")
    m = re.search(r'filename="?([^"]+)"?', cd, re.IGNORECASE)
    if m:
        suggested = safe_filename(m.group(1))
        if not suggested.lower().endswith(".zip"):
            suggested += ".zip"
        out_path = os.path.join(out_dir, suggested)

    total = int(resp.headers.get("Content-Length") or 0)
    tmp_path = out_path + ".part"

    with open(tmp_path, "wb") as f, tqdm(total=total, unit="B", unit_scale=True, unit_divisor=1024) as pbar:
        for chunk in resp.iter_content(chunk_size=262144):
            if not chunk:
                continue
            f.write(chunk)
            pbar.update(len(chunk))

    resp.close()
    os.replace(tmp_path, out_path)
    return out_path


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)

    session = requests.Session()
    session.headers.update(
        {
            "User-Agent": "ngs-sf-archive-downloader/1.2",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        }
    )

    spec = discover_endpoint_spec(session, FORM_URL)
    print("Discovered working request pattern:")
    print(f"  action_url:   {spec.action_url}")
    print(f"  method:       {spec.method}")
    print(f"  state_param:  {spec.state_param}")
    if spec.zip_param:
        print(f"  zip_param:    {spec.zip_param[0]}={spec.zip_param[1]}")
    else:
        print("  zip_param:    (none detected; server likely defaults to ZIP)")

    for region in REGIONS:
        print(f"Downloading: {region}")
        path = download_region(session, spec, region, OUT_DIR)
        print(f"  saved: {path}")
        time.sleep(SLEEP_SECONDS_BETWEEN_DOWNLOADS)

    print("Done.")


if __name__ == "__main__":
    main()
