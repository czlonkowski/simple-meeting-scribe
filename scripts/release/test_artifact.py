import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from artifact import validate


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.name = "Simple-Meeting-Scribe-0.1.0-arm64.dmg"
        (self.directory / self.name).write_bytes(b"synthetic DMG for checksum validation")
        self.digest = hashlib.sha256((self.directory / self.name).read_bytes()).hexdigest()
        self.manifest = dict(schemaVersion=1, version="0.1.0", buildNumber="1",
                             commit="a" * 40, sourceDirty=False, signed=True, notarized=True,
                             architecture="arm64", minimumMacOS="26.0", dmg=self.name, sha256=self.digest)
        self.save()
        (self.directory / "SHA256SUMS").write_text(f"{self.digest}  {self.name}\n")

    def save(self):
        (self.directory / "release.json").write_text(json.dumps(self.manifest))

    def test_valid_manifest_matches_exact_artifact(self):
        self.assertEqual(validate(self.directory)["commit"], "a" * 40)

    def test_rejects_unsigned_unnotarized_and_dirty_builds(self):
        for field, value in [("signed", False), ("notarized", False), ("sourceDirty", True), ("signed", "true")]:
            with self.subTest(field=field, value=value):
                previous = self.manifest[field]
                self.manifest[field] = value
                self.save()
                with self.assertRaises(ValueError):
                    validate(self.directory)
                self.manifest[field] = previous

    def test_rejects_modified_dmg(self):
        (self.directory / self.name).write_bytes(b"changed after verification")
        with self.assertRaisesRegex(ValueError, "checksum"):
            validate(self.directory)

    def test_rejects_changed_checksum_file(self):
        (self.directory / "SHA256SUMS").write_text("invalid\n")
        with self.assertRaisesRegex(ValueError, "SHA256SUMS"):
            validate(self.directory)

    def test_rejects_path_traversal(self):
        self.manifest["dmg"] = "../another.dmg"
        self.save()
        with self.assertRaisesRegex(ValueError, "filename"):
            validate(self.directory)

    def test_rejects_invalid_tag_metadata(self):
        for field, value in [("version", "0.1.0;bad"), ("commit", "main"), ("buildNumber", "0")]:
            with self.subTest(field=field):
                previous = self.manifest[field]
                self.manifest[field] = value
                self.save()
                with self.assertRaises(ValueError):
                    validate(self.directory)
                self.manifest[field] = previous


if __name__ == "__main__":
    unittest.main()
