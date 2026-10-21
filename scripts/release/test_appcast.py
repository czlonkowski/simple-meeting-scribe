from datetime import datetime, timezone
import unittest
from xml.etree import ElementTree

from appcast import SPARKLE, enclosure_url, published_build, render


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.manifest = dict(version="0.4.0", buildNumber="5", minimumMacOS="26.0",
                             dmg="Simple-Meeting-Scribe-0.4.0-arm64.dmg",
                             sparkle=dict(edSignature="A" * 86 + "==", length=1234))

    def parse(self, notes="<p>Fixed &amp; improved</p>"):
        xml = render(self.manifest, notes, datetime(2026, 10, 14, tzinfo=timezone.utc))
        return ElementTree.fromstring(xml)

    def test_item_matches_release(self):
        item = self.parse().find("channel/item")
        self.assertEqual(item.find(f"{{{SPARKLE}}}version").text, "5")
        self.assertEqual(item.find(f"{{{SPARKLE}}}shortVersionString").text, "0.4.0")
        self.assertEqual(item.find(f"{{{SPARKLE}}}minimumSystemVersion").text, "26.0")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"),
                         "https://github.com/czlonkowski/simple-meeting-scribe/releases/download/v0.4.0/"
                         "Simple-Meeting-Scribe-0.4.0-arm64.dmg")
        self.assertEqual(enclosure.get("length"), "1234")
        self.assertEqual(enclosure.get(f"{{{SPARKLE}}}edSignature"), "A" * 86 + "==")
        self.assertIn("Fixed &amp; improved", item.find("description").text)

    def test_enclosure_url_uses_version_tag(self):
        self.assertTrue(enclosure_url(self.manifest).endswith("/download/v0.4.0/Simple-Meeting-Scribe-0.4.0-arm64.dmg"))

    def test_rejects_notes_that_break_cdata(self):
        with self.assertRaises(ValueError):
            self.parse("<p>]]></p>")

    def test_published_build_reads_highest_version(self):
        xml = render(self.manifest, "", datetime(2026, 10, 14, tzinfo=timezone.utc))
        self.assertEqual(published_build(xml), 5)
        with self.assertRaises(ValueError):
            published_build("<rss><channel/></rss>")


if __name__ == "__main__":
    unittest.main()
