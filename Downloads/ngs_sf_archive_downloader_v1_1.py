#!/usr/bin/env python3
"""ngs_sf_archive_downloader.py

Downloads NGS archived shapefile bundles from:
    https://geodesy.noaa.gov/cgi-bin/sf_archive.prl

This page's HTML has historically changed; in some versions the "Pick a State"
control is a <select>, and in others it is a grid of submit buttons. This script
auto-detects either layout.

Install:
    python -m pip install requests beautifulsoup4 tqdm

Run:
    python ngs_sf_archive_downloader.py
"""

from __future__ import annotations

import os
import re
import time
from dataclasses import dataclass
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup
from tqdm import tqdm

FORM_URL = "https://geodesy.noaa.gov/cgi-bin/sf_archive.prl"
OUT_DIR = "ngs_sf_archive_downloads"

# Be a good citizen
SLEEP_SECONDS_BETWEEN_DOWNLOADS = 1.0
TIMEOUT = 60

# Heuristics for filtering non-state buttons
_BAD_BUTTON_VALUES = {
    "submit", "reset", "clear", "go", "download", "return", "home", "datasheet page", "ngs home page"
}


@dataclass
class FormSpec:
    action_url: str
    method: str
    hidden_fields: dict[str, str]

    state_field_name: str
    state_options: list[tuple[str, str]]  # (value, label)

    compression_field_name: str | None
    compression_zip_value: str | None


def _looks_like_region_label(s: str) -> bool:
    s = (s or "").strip()
    if not s:
        return False
    low = s.lower()
    if low in _BAD_BUTTON_VALUES:
        return False
    if "zip" in low or "tar" in low:
        return False
    # Common: ALL CAPS with spaces/commas; allow numbers (e.g., U1 FOR NAD83 2011)
    return bool(re.fullmatch(r"[A-Z0-9 ,.'-]{3,}", s))


def _pick_zip_option(form) -> tuple[str, str] | tuple[None, None]:
    """Find a compression option that corresponds to ZIP.

    Returns (name, value), or (None, None) if no explicit ZIP control is found.
    """
    # Radio inputs first
    radios = form.select("input[type=radio], input[type=RADIO]")
    for r in radios:
        name = r.get("name")
        value = r.get("value", "")
        if name and re.search(r"zip", value, re.IGNORECASE):
            return name, value

    # Select dropdown option
    for s in form.select("select"):
        sname = s.get("name")
        if not sname:
            continue
        for opt in s.select("option"):
            val = opt.get("value", "") or ""
            label = opt.get_text(" ", strip=True) or ""
            if re.search(r"zip", val, re.IGNORECASE) or re.search(r"zip", label, re.IGNORECASE):
                return sname, val or label

    # Sometimes compression is also implemented as submit buttons
    buttons = []
    buttons.extend(form.select("input[type=submit], input[type=SUBMIT]"))
    buttons.extend(form.select("button"))
    for b in buttons:
        name = b.get("name")
        value = b.get("value") or b.get_text(" ", strip=True)
        if name and value and re.search(r"zip", value, re.IGNORECASE):
            return name, value

    return None, None


def _discover_state_control(form) -> tuple[str, list[tuple[str, str]]]:
    """Discover the state/region control.

    Priority:
      1) <select> with the most options
      2) group of submit buttons sharing the same 'name'
    """
    selects = form.select("select")
    if selects:
        select = max(selects, key=lambda s: len(s.select("option")))
        select_name = select.get("name")
        if not select_name:
            raise RuntimeError("Discovered a <select> for states, but it has no name attribute.")
        options: list[tuple[str, str]] = []
        for opt in select.select("option"):
            label = opt.get_text(" ", strip=True)
            value = opt.get("value") if opt.get("value") is not None else label
            if not _looks_like_region_label((label or "").upper()):
                continue
            options.append((value, label))
        if not options:
            raise RuntimeError("Found a <select>, but no usable state/region options were detected.")
        return select_name, options

    # Fallback: submit buttons
    candidates: dict[str, list[str]] = {}
    for inp in form.select("input[type=submit], input[type=SUBMIT]"):
        name = inp.get("name")
        value = inp.get("value", "")
        if not name or not value:
            continue
        if _looks_like_region_label(value.strip()):
            candidates.setdefault(name, []).append(value.strip())

    # Some pages use <button> instead of <input type=submit>
    for btn in form.select("button"):
        name = btn.get("name")
        value = (btn.get("value") or btn.get_text(" ", strip=True) or "").strip()
        if not name or not value:
            continue
        if _looks_like_region_label(value):
            candidates.setdefault(name, []).append(value)

    if not candidates:
        raise RuntimeError(
            "Could not find a <select> OR a set of submit buttons for state/region selection."
        )

    # Choose the field name that has the most distinct region values
    state_name = max(candidates.keys(), key=lambda k: len(set(candidates[k])))
    values = sorted(set(candidates[state_name]))
    options = [(v, v) for v in values]
    return state_name, options


def parse_form_spec(html: str, base_url: str) -> FormSpec:
    soup = BeautifulSoup(html, "html.parser")
    form = soup.find("form")
    if not form:
        raise RuntimeError("No <form> found on the page; the site may have changed.")

    action = form.get("action") or base_url
    action_url = urljoin(base_url, action)
    method = (form.get("method") or "GET").upper()

    hidden_fields: dict[str, str] = {}
    for inp in form.select("input[type=hidden], input[type=HIDDEN]"):
        name = inp.get("name")
        if name:
            hidden_fields[name] = inp.get("value", "")

    state_field_name, state_options = _discover_state_control(form)
    compression_field_name, compression_zip_value = _pick_zip_option(form)

    return FormSpec(
        action_url=action_url,
        method=method,
        hidden_fields=hidden_fields,
        state_field_name=state_field_name,
        state_options=state_options,
        compression_field_name=compression_field_name,
        compression_zip_value=compression_zip_value,
    )


def safe_filename(name: str) -> str:
    name = re.sub(r"[^\w\-. ]+", "_", name).strip()
    return re.sub(r"\s+", "_", name)


def _request(session: requests.Session, spec: FormSpec, payload: dict[str, str], stream: bool = True) -> requests.Response:
    if spec.method == "POST":
        return session.post(spec.action_url, data=payload, stream=stream, timeout=TIMEOUT)
    return session.get(spec.action_url, params=payload, stream=stream, timeout=TIMEOUT)


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)

    session = requests.Session()
    session.headers.update(
        {
            "User-Agent": "ngs-sf-archive-downloader/1.1",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        }
    )

    r = session.get(FORM_URL, timeout=TIMEOUT)
    r.raise_for_status()

    spec = parse_form_spec(r.text, FORM_URL)

    print(f"Form action: {spec.action_url}")
    print(f"Method: {spec.method}")
    print(f"State field: {spec.state_field_name}  (options: {len(spec.state_options)})")
    if spec.compression_field_name and spec.compression_zip_value:
        print(f"ZIP compression: {spec.compression_field_name}={spec.compression_zip_value}")
    else:
        print("ZIP compression control: not explicitly detected (will attempt download with state-only request).")

    for value, label in spec.state_options:
        payload = dict(spec.hidden_fields)
        payload[spec.state_field_name] = value

        # If a ZIP option exists, request ZIP explicitly
        if spec.compression_field_name and spec.compression_zip_value:
            payload[spec.compression_field_name] = spec.compression_zip_value

        out_path = os.path.join(OUT_DIR, f"{safe_filename(label)}.zip")
        if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
            print(f"Skipping (exists): {label}")
            continue

        print(f"Downloading: {label}")
        resp = _request(session, spec, payload, stream=True)
        resp.raise_for_status()

        # Prefer server-provided filename if present
        cd = resp.headers.get("Content-Disposition", "")
        m = re.search(r'filename="?([^"]+)"?', cd, re.IGNORECASE)
        if m:
            suggested = safe_filename(m.group(1))
            # Ensure we end with .zip for convenience (some servers omit extension)
            if not suggested.lower().endswith(".zip"):
                suggested += ".zip"
            out_path = os.path.join(OUT_DIR, suggested)

        total = int(resp.headers.get("Content-Length") or 0)
        tmp_path = out_path + ".part"

        with open(tmp_path, "wb") as f, tqdm(total=total, unit="B", unit_scale=True, unit_divisor=1024) as pbar:
            for chunk in resp.iter_content(chunk_size=262144):
                if not chunk:
                    continue
                f.write(chunk)
                pbar.update(len(chunk))

        os.replace(tmp_path, out_path)
        time.sleep(SLEEP_SECONDS_BETWEEN_DOWNLOADS)

    print("Done.")


if __name__ == "__main__":
    main()
