#!/usr/bin/env python3
"""
Generate a state-pack manifest.json from a directory of CSV files.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from dataclasses import dataclass
from datetime import datetime, date
from pathlib import Path
from typing import Optional, List, Dict


STATE_NAMES: Dict[str, str] = {
    "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California",
    "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware", "FL": "Florida", "GA": "Georgia",
    "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa",
    "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
    "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri",
    "MT": "Montana", "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey",
    "NM": "New Mexico", "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio",
    "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina",
    "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont",
    "VA": "Virginia", "WA": "Washington", "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
    "DC": "District of Columbia",
}

FILENAME_RE = re.compile(r'^(?:pois[_-])?(?P<code>[A-Za-z]{2})(?:[_-](?P<ymd>\d{8}))?\.csv$')


@dataclass(frozen=True)
class StateEntry:
    code: str
    name: str
    version: str
    bytes: int
    sha256: str
    url: str


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def version_from_ymd(ymd: str) -> str:
    return datetime.strptime(ymd, "%Y%m%d").date().isoformat()


def version_from_mtime(path: Path) -> str:
    return datetime.fromtimestamp(path.stat().st_mtime).date().isoformat()


def build_url(base_url: str, filename: str) -> str:
    return base_url.rstrip("/") + "/" + filename


def scan_directory(directory: Path, base_url: str, default_version: Optional[str], strict: bool) -> List[StateEntry]:
    entries: List[StateEntry] = []
    seen: set[str] = set()

    for p in sorted(directory.iterdir()):
        if not p.is_file() or p.suffix.lower() != ".csv":
            continue

        m = FILENAME_RE.match(p.name)
        if not m:
            continue

        code = m.group("code").upper()
        if strict and code not in STATE_NAMES:
            continue

        if code in seen:
            raise SystemExit(f"Duplicate state code detected: {code}")
        seen.add(code)

        name = STATE_NAMES.get(code, code)
        ymd = m.group("ymd")

        if ymd:
            version = version_from_ymd(ymd)
        elif default_version:
            version = default_version
        else:
            version = version_from_mtime(p)

        size_bytes = p.stat().st_size
        digest = sha256_file(p)
        url = build_url(base_url, p.name)

        entries.append(StateEntry(code, name, version, size_bytes, digest, url))

    return sorted(entries, key=lambda e: e.name)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--output", default="manifest.json")
    parser.add_argument("--updated-at", default=date.today().isoformat())
    parser.add_argument("--schema-version", type=int, default=1)
    parser.add_argument("--default-version")
    parser.add_argument("--no-strict", action="store_true")

    args = parser.parse_args()

    directory = Path(args.directory).expanduser().resolve()
    if not directory.is_dir():
        raise SystemExit(f"Invalid directory: {directory}")

    entries = scan_directory(directory, args.base_url, args.default_version, not args.no_strict)

    manifest = {
        "schemaVersion": args.schema_version,
        "updatedAt": args.updated_at,
        "states": [
            {
                "code": e.code,
                "name": e.name,
                "version": e.version,
                "bytes": e.bytes,
                "sha256": e.sha256,
                "url": e.url,
            }
            for e in entries
        ],
    }

    out = Path(args.output).expanduser().resolve()
    with out.open("w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")

    print(f"Wrote {out} with {len(entries)} states.")


if __name__ == "__main__":
    main()
