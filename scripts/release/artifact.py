#!/usr/bin/env python3
"""Validate the release manifest and DMG checksum before any GitHub operation."""
import hashlib
import json
from pathlib import Path
import re
import sys


def validate(directory):
    directory = Path(directory)
    manifest = json.loads((directory / "release.json").read_text())
    if manifest.get("schemaVersion") != 1:
        raise ValueError("Unsupported release manifest")
    if manifest.get("signed") is not True or manifest.get("notarized") is not True:
        raise ValueError("Only signed and notarized releases can be uploaded")
    if manifest.get("sourceDirty") is not False:
        raise ValueError("Release must come from a clean commit")
    version = manifest.get("version", "")
    commit = manifest.get("commit", "")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Invalid release version")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid source commit")
    if not re.fullmatch(r"[1-9][0-9]*", manifest.get("buildNumber", "")):
        raise ValueError("Invalid build number")
    if manifest.get("architecture") != "arm64" or manifest.get("minimumMacOS") != "26.0":
        raise ValueError("Unexpected platform")
    expected_name = f"Simple-Meeting-Scribe-{version}-arm64.dmg"
    if manifest.get("dmg") != expected_name:
        raise ValueError("Unexpected DMG filename")
    hasher = hashlib.sha256()
    with (directory / expected_name).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    if manifest.get("sha256") != digest:
        raise ValueError("DMG checksum does not match the release manifest")
    if (directory / "SHA256SUMS").read_text() != f"{digest}  {expected_name}\n":
        raise ValueError("SHA256SUMS does not match the DMG")
    return manifest


if __name__ == "__main__":
    try:
        result = validate(sys.argv[1])
        print("\t".join([result["version"], result["commit"], result["dmg"]]))
    except (ValueError, OSError, KeyError, IndexError) as error:
        sys.exit(f"Release validation failed: {error}")
