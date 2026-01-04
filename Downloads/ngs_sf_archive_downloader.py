#!/usr/bin/env python3
"""
Download all NGS archived shapefile bundles from:
https://geodesy.noaa.gov/cgi-bin/sf_archive.prl

Requirements:
    pip install requests beautifulsoup4 tqdm
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


@dataclass
class FormSpec:
    action_url: str
    method: str
    hidden_fields: dict[str, str]
    select_name: str
    select_options: list[tuple[str, str]]  # (value, label)
    compression_name: str
    compression_zip_value: str


def _pick_zip_option(form) -> tuple[str, str]:
    """Find a compression option that corresponds to ZIP."""
    radios = form.select("input[type=radio], input[type=RADIO]")
    for r in radios:
        name = r.get("name")
        value = r.get("value", "")
        if name and re.search(r"zip", value, re.IGNORECASE):
            return name, value

    selects = form.select("select")
    for s in selects:
        for opt in s.select("option"):
            val = opt.get("value", "")
            label = opt.get_text(" ", strip=True)
            if re.search(r"zip", val, re.IGNORECASE) or re.search(r"zip", label, re.IGNORECASE):
                return s.get("name"), val

    raise RuntimeError("Could not find a ZIP compression option in the form.")


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

    selects = form.select("select")
    if not selects:
        raise RuntimeError("No <select> found; cannot discover state list automatically.")

    select = max(selects, key=lambda s: len(s.select("option")))
    select_name = select.get("name")
    if not select_name:
        raise RuntimeError("State select has no name attribute.")

    options: list[tuple[str, str]] = []
    for opt in select.select("option"):
        value = opt.get("value")
        label = opt.get_text(" ", strip=True)
        if value is None:
            value = label
        if not label or re.search(r"pick a state|select", label, re.IGNORECASE):
            continue
        options.append((value, label))

    compression_name, compression_zip_value = _pick_zip_option(form)

    return FormSpec(
        action_url=action_url,
        method=method,
        hidden_fields=hidden_fields,
        select_name=select_name,
        select_options=options,
        compression_name=compression_name,
        compression_zip_value=compression_zip_value,
    )


def safe_filename(name: str) -> str:
    name = re.sub(r"[^\w\-. ]+", "_", name).strip()
    return re.sub(r"\s+", "_", name)


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)

    session = requests.Session()
    session.headers.update({
        "User-Agent": "ngs-sf-archive-downloader/1.0",
        "Accept": "*/*",
    })

    r = session.get(FORM_URL, timeout=TIMEOUT)
    r.raise_for_status()

    spec = parse_form_spec(r.text, FORM_URL)

    for value, label in spec.select_options:
        data = dict(spec.hidden_fields)
        data[spec.select_name] = value
        data[spec.compression_name] = spec.compression_zip_value

        out_path = os.path.join(OUT_DIR, f"{safe_filename(label)}.zip")
        if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
            continue

        req = session.post if spec.method == "POST" else session.get

        with req(spec.action_url,
                 data=data if spec.method == "POST" else None,
                 params=data if spec.method != "POST" else None,
                 stream=True,
                 timeout=TIMEOUT) as resp:

            resp.raise_for_status()

            cd = resp.headers.get("Content-Disposition", "")
            m = re.search(r'filename="?([^"]+)"?', cd, re.IGNORECASE)
            if m:
                out_path = os.path.join(OUT_DIR, safe_filename(m.group(1)))

            total = int(resp.headers.get("Content-Length") or 0)
            tmp_path = out_path + ".part"

            with open(tmp_path, "wb") as f, tqdm(total=total, unit="B", unit_scale=True) as pbar:
                for chunk in resp.iter_content(chunk_size=262144):
                    if chunk:
                        f.write(chunk)
                        pbar.update(len(chunk))

            os.replace(tmp_path, out_path)

        time.sleep(SLEEP_SECONDS_BETWEEN_DOWNLOADS)


if __name__ == "__main__":
    main()
