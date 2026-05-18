#!/usr/bin/env python3
"""
Resolve the latest Bliss OS 14 FOSS ISO download URL by scraping the
SourceForge directory listing page.

SourceForge embeds download links in the HTML directory listing page.
We extract all .iso/download hrefs, parse the date from the filename
(format: ...-YYYYMMDD.iso), and pick the newest one.

Usage:
  python3 resolve-blissos-url.py [--path <sf-path>] [--filter <substring>]

Outputs two lines to stdout:
  url=<direct-download-url>
  filename=<filename>

Exit 1 if no matching file is found or the page is unreachable.
"""
import re
import sys
import urllib.request
import urllib.error
import argparse

SF_FILES_BASE = "https://sourceforge.net/projects/{project}/files/{path}/"
PROJECT = "blissos-x86"
DEFAULT_PATH = "Official/BlissOS14/FOSS/Generic"
DEFAULT_FILTER = ".iso"

# Matches: https://sourceforge.net/projects/.../files/.../SomeName.iso/download
_HREF_RE = re.compile(
    r'href="(https://sourceforge\.net/projects/[^"]+?/files/[^"]+?'
    r'(/([^"/]+\.iso))/download)"'
)

# Date embedded in Bliss OS filenames: ...-YYYYMMDD.iso
_DATE_RE = re.compile(r"-(\d{8})\.iso$", re.IGNORECASE)


def fetch_page(project: str, path: str) -> str:
    url = SF_FILES_BASE.format(project=project, path=path.strip("/"))
    req = urllib.request.Request(url, headers={"User-Agent": "curl/7.88"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        sys.exit(f"SourceForge returned HTTP {e.code} for {url}")
    except urllib.error.URLError as e:
        sys.exit(f"Failed to reach SourceForge: {e.reason}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path",   default=DEFAULT_PATH,   help="SourceForge file path under the project")
    parser.add_argument("--filter", default=DEFAULT_FILTER, help="Substring the filename must contain")
    args = parser.parse_args()

    html = fetch_page(PROJECT, args.path)

    candidates = []
    seen = set()
    for m in _HREF_RE.finditer(html):
        download_url = m.group(1)   # full .../foo.iso/download URL
        name = m.group(3)           # just the filename

        if name in seen:
            continue
        if args.filter.lower() not in name.lower():
            continue
        seen.add(name)

        date_m = _DATE_RE.search(name)
        sort_key = date_m.group(1) if date_m else ""
        candidates.append((sort_key, name, download_url))

    if not candidates:
        sys.exit(
            f"No files matching '{args.filter}' found at "
            f"sourceforge.net/projects/{PROJECT}/files/{args.path}/"
        )

    # Newest date first
    candidates.sort(key=lambda t: t[0], reverse=True)
    _date, name, download_url = candidates[0]

    print(f"url={download_url}")
    print(f"filename={name}")
    print(f"candidates_found={len(candidates)}", file=sys.stderr)


if __name__ == "__main__":
    main()
