#!/usr/bin/env python3
"""Write the one-item Sparkle appcast for a validated release.

The appcast is uploaded with the DMG; published releases serve it from
/releases/latest/download/appcast.xml, so publishing a draft is the rollout.
"""
import argparse
from email.utils import format_datetime
from datetime import datetime, timezone
from pathlib import Path
import re
import sys
from urllib.request import urlopen
from urllib.error import HTTPError
from xml.etree import ElementTree
from xml.sax.saxutils import escape, quoteattr

from artifact import validate

REPOSITORY = "czlonkowski/simple-meeting-scribe"
FEED_URL = f"https://github.com/{REPOSITORY}/releases/latest/download/appcast.xml"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def enclosure_url(manifest):
    return f"https://github.com/{REPOSITORY}/releases/download/v{manifest['version']}/{manifest['dmg']}"


def render(manifest, notes_html, published=None, url=None):
    if "]]>" in notes_html:
        raise ValueError("Release notes HTML cannot contain ']]>'")
    published = published or datetime.now(timezone.utc)
    version, build = manifest["version"], manifest["buildNumber"]
    sparkle = manifest["sparkle"]
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE}">
  <channel>
    <title>Simple Meeting Scribe</title>
    <link>{escape(FEED_URL)}</link>
    <item>
      <title>Version {escape(version)}</title>
      <pubDate>{format_datetime(published)}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(manifest['minimumMacOS'])}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{escape(f"https://github.com/{REPOSITORY}/releases/tag/v{version}")}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[{notes_html}]]></description>
      <enclosure url={quoteattr(url or enclosure_url(manifest))} length="{sparkle['length']}" type="application/octet-stream" sparkle:edSignature={quoteattr(sparkle['edSignature'])}/>
    </item>
  </channel>
</rss>
"""


def published_build(xml_text):
    """Highest sparkle:version in an appcast."""
    root = ElementTree.fromstring(xml_text)
    builds = [int(node.text) for node in root.iter(f"{{{SPARKLE}}}version") if node.text and node.text.isdigit()]
    if not builds:
        raise ValueError("Published appcast has no sparkle:version")
    return max(builds)


def check_newer(build, feed_url=FEED_URL):
    """Sparkle offers only a higher CFBundleVersion; refuse a build that users would never get."""
    try:
        with urlopen(feed_url, timeout=30) as response:
            current = published_build(response.read().decode())
    except HTTPError as error:
        if error.code == 404:
            return None  # No published release carries an appcast yet.
        raise
    if int(build) <= current:
        raise ValueError(f"Build {build} is not newer than published build {current}")
    return current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    write = sub.add_parser("write")
    write.add_argument("artifacts", type=Path)
    write.add_argument("notes_html", type=Path)
    write.add_argument("output", type=Path)
    write.add_argument("--test-enclosure-url",
                       help="Update tests only: where a TESTFEED build's DMG is hosted")
    newer = sub.add_parser("check-newer")
    newer.add_argument("build")
    args = parser.parse_args()
    try:
        if args.command == "write":
            test = args.test_enclosure_url
            manifest = validate(args.artifacts, allow_test_feed=bool(test))
            if bool(test) != bool(manifest.get("testFeed")):
                raise ValueError("--test-enclosure-url is for TESTFEED builds only")
            if test and not test.startswith("https://"):
                raise ValueError("Test enclosure URL must be https")
            args.output.write_text(render(manifest, args.notes_html.read_text(), url=test))
            ElementTree.parse(args.output)
        else:
            if not re.fullmatch(r"[1-9][0-9]*", args.build):
                raise ValueError("Invalid build number")
            current = check_newer(args.build)
            print(f"Published build: {current if current is not None else 'none'}")
    except (ValueError, OSError, KeyError, ElementTree.ParseError) as error:
        sys.exit(f"Appcast failed: {error}")


if __name__ == "__main__":
    main()
