#
# test_fetch.py: tests for engines/scripts/fetch.py
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Run with: python3 -m unittest discover -s engines/tests
#

import copy
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import fetch  # noqa: E402

INPUTS = Path(__file__).resolve().parent.parent / "inputs.json"


def entry_for(path, **overrides):
    data = path.read_bytes()
    entry = {
        "id": "test", "name": "Test", "version": "1", "file": path.name + ".out",
        "url": path.as_uri(), "sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
        "license": "MIT", "checksumSource": "test", "milestone": "M1",
    }
    entry.update(overrides)
    return entry


class ValidateTests(unittest.TestCase):
    def test_the_real_inputs_file_is_valid(self):
        inputs = fetch.validate(fetch.load(INPUTS))
        ids = {entry["id"] for entry in inputs}
        for required in ("crossover-sources", "llvm-mingw", "gmp", "nettle", "freetype", "sdl2",
                         "libinotify-kqueue", "dxmt", "dxmt-license"):
            self.assertIn(required, ids)

    def test_the_crossover_drop_lists_the_five_modified_components(self):
        drop = next(e for e in fetch.load(INPUTS)["inputs"] if e["id"] == "crossover-sources")
        components = {p["component"] for p in drop["provides"] if p["modifiedByCodeWeavers"]}
        self.assertEqual(components, {"wine", "gnutls", "moltenvk", "vkd3d", "dxvk"})

    def test_rejects_bad_entries_and_names_every_problem(self):
        document = fetch.load(INPUTS)
        bad = copy.deepcopy(document)
        bad["inputs"][0]["sha256"] = "ABC"
        bad["inputs"][1]["url"] = "http://example.com/file"
        bad["inputs"][2]["file"] = "../escape"
        bad["inputs"][3]["id"] = bad["inputs"][4]["id"]
        del bad["inputs"][5]["license"]
        with self.assertRaises(fetch.InputError) as caught:
            fetch.validate(bad)
        message = str(caught.exception)
        for fragment in ("sha256 must be", "url must use https", "must be a plain name", "duplicate id", "missing license"):
            self.assertIn(fragment, message)

    def test_milestone_selection(self):
        inputs = fetch.validate(fetch.load(INPUTS))
        m1 = {entry["id"] for entry in fetch.select(inputs, milestone="M1")}
        self.assertEqual(m1, {"llvm-mingw"})
        self.assertIn("crossover-sources", {e["id"] for e in fetch.select(inputs, milestone="M2")})
        with self.assertRaises(fetch.InputError):
            fetch.select(inputs, only=["nope"])


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.source = self.folder / "source.bin"
        self.source.write_bytes(b"schnitzel" * 1000)
        self.dest = self.folder / "dest"
        self.dest.mkdir()
        self.log = []

    def fetch(self, entry):
        fetch.validate({"schemaVersion": 1, "inputs": [entry]}, allow_insecure=True)
        return fetch.download(entry, self.dest, retries=1, log=self.log.append, allow_insecure=True)

    def test_downloads_and_verifies(self):
        path = self.fetch(entry_for(self.source))
        self.assertEqual(path.read_bytes(), self.source.read_bytes())
        self.assertFalse(any(p.suffix == ".part" for p in self.dest.iterdir()))

    def test_rejects_a_wrong_checksum_and_keeps_nothing(self):
        entry = entry_for(self.source, sha256="0" * 64)
        with self.assertRaises(fetch.InputError) as caught:
            self.fetch(entry)
        self.assertIn("doesn't match its pin", str(caught.exception))
        self.assertEqual(list(self.dest.iterdir()), [])

    def test_rejects_a_wrong_size(self):
        with self.assertRaises(fetch.InputError):
            self.fetch(entry_for(self.source, size=1))
        self.assertEqual(list(self.dest.iterdir()), [])

    def test_keeps_a_valid_file_without_downloading(self):
        entry = entry_for(self.source)
        self.fetch(entry)
        self.source.unlink()  # Would fail if it tried to download again.
        self.fetch(entry)
        self.assertIn("already downloaded", self.log[-1])

    def test_replaces_a_damaged_file(self):
        entry = entry_for(self.source)
        (self.dest / entry["file"]).write_bytes(b"damaged")
        path = self.fetch(entry)
        self.assertEqual(path.read_bytes(), self.source.read_bytes())
        self.assertTrue(any("doesn't match" in line for line in self.log))

    def test_reports_an_unreachable_url(self):
        entry = entry_for(self.source, url=(self.folder / "missing.bin").as_uri())
        with self.assertRaises(fetch.InputError) as caught:
            self.fetch(entry)
        self.assertIn("couldn't download", str(caught.exception))


class CommandLineTests(unittest.TestCase):
    def test_check_mode_succeeds_on_the_real_file(self):
        self.assertEqual(fetch.main(["--check", "--inputs", str(INPUTS)]), 0)

    def test_check_mode_fails_on_a_broken_file(self):
        broken = Path(tempfile.mkdtemp()) / "inputs.json"
        broken.write_text(json.dumps({"schemaVersion": 1, "inputs": [{"id": "x"}]}))
        self.assertEqual(fetch.main(["--check", "--inputs", str(broken)]), 1)


if __name__ == "__main__":
    unittest.main()
