#!/usr/bin/env python3
#
# fetch.py: downloads the engine build's inputs and checks their SHA-256.
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage:
#   python3 engines/scripts/fetch.py --check                    check inputs.json only
#   python3 engines/scripts/fetch.py --dest DIR                 download everything to DIR
#   python3 engines/scripts/fetch.py --dest DIR --only gmp,sdl2 download some inputs
#   python3 engines/scripts/fetch.py --dest DIR --milestone M1  inputs a milestone needs
#
# Files already in DIR with the right size and SHA-256 are kept. A download whose size or
# SHA-256 doesn't match is deleted and the script fails, so a bad file is never used.
# Downloads use curl, which is on every Mac and GitHub runner and uses the system's
# certificate store (some Python installs have none). Otherwise only the Python standard
# library is used (Python 3.9 or later).

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

SCHEMA_VERSION = 1
REQUIRED_KEYS = ("id", "name", "version", "file", "url", "sha256", "size", "license", "checksumSource", "milestone")
MILESTONE = re.compile(r"^M[1-9]$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SAFE_FILE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
USER_AGENT = "Schnitzel-engine-build (+https://github.com/Tennessene/Schnitzel)"
CHUNK = 1 << 20


class InputError(Exception):
    """inputs.json is malformed or a download doesn't match its pin."""


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def validate(document, allow_insecure=False):
    """Returns the list of inputs, or raises InputError naming every problem found."""
    problems = []
    if document.get("schemaVersion") != SCHEMA_VERSION:
        problems.append(f"schemaVersion must be {SCHEMA_VERSION}")
    inputs = document.get("inputs")
    if not isinstance(inputs, list) or not inputs:
        raise InputError("inputs must be a non-empty list")

    seen_ids, seen_files = set(), set()
    for index, entry in enumerate(inputs):
        label = entry.get("id", f"#{index}") if isinstance(entry, dict) else f"#{index}"
        if not isinstance(entry, dict):
            problems.append(f"{label}: must be an object")
            continue
        for key in REQUIRED_KEYS:
            if key not in entry or entry[key] in ("", None):
                problems.append(f"{label}: missing {key}")
        if entry.get("id") in seen_ids:
            problems.append(f"{label}: duplicate id")
        seen_ids.add(entry.get("id"))
        if entry.get("file") in seen_files:
            problems.append(f"{label}: duplicate file name")
        seen_files.add(entry.get("file"))
        if "file" in entry and not SAFE_FILE.match(str(entry["file"])):
            problems.append(f"{label}: file name {entry['file']!r} must be a plain name")
        if "sha256" in entry and not SHA256.match(str(entry["sha256"])):
            problems.append(f"{label}: sha256 must be 64 lowercase hex characters")
        if "size" in entry and (not isinstance(entry["size"], int) or entry["size"] <= 0):
            problems.append(f"{label}: size must be a positive number of bytes")
        if "milestone" in entry and not MILESTONE.match(str(entry["milestone"])):
            problems.append(f"{label}: milestone must look like M1 to M9")
        url = str(entry.get("url", ""))
        if not (url.startswith("https://") or (allow_insecure and url.startswith(("http://", "file://")))):
            problems.append(f"{label}: url must use https")
    if problems:
        raise InputError("inputs.json has problems:\n  " + "\n  ".join(problems))
    return inputs


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_valid(path, entry):
    return path.is_file() and path.stat().st_size == entry["size"] and sha256_of(path) == entry["sha256"]


def transfer(url, path, allow_insecure=False):
    """Downloads `url` to `path` with curl. Raises on any failure."""
    curl = shutil.which("curl")
    if not curl:
        raise RuntimeError("curl is required but wasn't found")
    command = [curl, "--fail", "--location", "--silent", "--show-error", "--max-time", "1800",
               "--user-agent", USER_AGENT, "--output", str(path)]
    if not allow_insecure:
        command += ["--proto", "=https", "--proto-redir", "=https"]
    result = subprocess.run(command + [url], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError((result.stderr or "").strip() or f"curl exited with {result.returncode}")


def download(entry, destination, retries=3, log=print, allow_insecure=False):
    """Downloads one input into `destination` (a folder), checks it and returns its path."""
    target = destination / entry["file"]
    if is_valid(target, entry):
        log(f"ok      {entry['id']} {entry['version']} (already downloaded)")
        return target
    if target.exists():
        log(f"replace {entry['id']}: the existing file doesn't match its pin")
        target.unlink()

    partial = destination / (entry["file"] + ".part")
    last_error = None
    for attempt in range(1, retries + 1):
        try:
            transfer(entry["url"], partial, allow_insecure=allow_insecure)
            size = partial.stat().st_size
            actual = sha256_of(partial)
            if size != entry["size"] or actual != entry["sha256"]:
                partial.unlink(missing_ok=True)
                # A mismatch is not retried: the file is wrong, not the connection.
                raise InputError(
                    f"{entry['id']}: download doesn't match its pin\n"
                    f"  expected {entry['size']} bytes, sha256 {entry['sha256']}\n"
                    f"  got      {size} bytes, sha256 {actual}\n"
                    f"  from {entry['url']}")
            os.replace(partial, target)
            log(f"fetched {entry['id']} {entry['version']} ({size} bytes, sha256 ok)")
            return target
        except InputError:
            raise
        except Exception as error:  # Network errors: try again.
            partial.unlink(missing_ok=True)
            last_error = error
            if attempt < retries:
                log(f"retry   {entry['id']}: {error} (attempt {attempt} of {retries})")
                time.sleep(2 * attempt)
    raise InputError(f"{entry['id']}: couldn't download {entry['url']}: {last_error}")


def select(inputs, only=None, milestone=None):
    chosen = inputs
    if only:
        wanted = set(only)
        unknown = wanted - {entry["id"] for entry in inputs}
        if unknown:
            raise InputError("unknown input id(s): " + ", ".join(sorted(unknown)))
        chosen = [entry for entry in chosen if entry["id"] in wanted]
    if milestone:
        limit = int(milestone[1:])
        chosen = [entry for entry in chosen if int(entry["milestone"][1:]) <= limit]
    return chosen


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", default=str(Path(__file__).resolve().parent.parent / "inputs.json"))
    parser.add_argument("--dest", help="folder to download into")
    parser.add_argument("--check", action="store_true", help="only check inputs.json")
    parser.add_argument("--only", help="comma-separated input ids")
    parser.add_argument("--milestone", help="inputs needed up to this milestone, e.g. M2")
    parser.add_argument("--summary", help="append a Markdown table of the inputs to this file")
    args = parser.parse_args(argv)

    try:
        inputs = validate(load(args.inputs))
        if args.milestone and not MILESTONE.match(args.milestone):
            raise InputError("--milestone must look like M1 to M9")
        chosen = select(inputs, args.only.split(",") if args.only else None, args.milestone)
        if args.summary:
            with open(args.summary, "a", encoding="utf-8") as summary:
                summary.write("| Input | Version | SHA-256 | Milestone |\n|---|---|---|---|\n")
                for entry in chosen:
                    summary.write(f"| {entry['name']} | {entry['version']} | `{entry['sha256'][:16]}…` | {entry['milestone']} |\n")
        if args.check:
            print(f"inputs.json is valid: {len(inputs)} inputs")
            return 0
        if not args.dest:
            raise InputError("--dest is required unless --check is given")
        destination = Path(args.dest)
        destination.mkdir(parents=True, exist_ok=True)
        for entry in chosen:
            download(entry, destination)
        print(f"all {len(chosen)} inputs present and verified in {destination}")
        return 0
    except InputError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
