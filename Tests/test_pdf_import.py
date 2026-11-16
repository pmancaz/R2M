"""Exercise PDF extraction with disposable real documents and no model weights."""
from pathlib import Path
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

import pymupdf

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
from reader import read_pdf


class PDFImport(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        override = patch.dict(os.environ, {"R2M_MODEL_DIR": str(self.directory / "no-models")})
        override.start()
        self.addCleanup(override.stop)

    def read(self, path):
        return read_pdf(path, "Fixture", lambda message: None)

    def test_academic_columns_read_left_then_right(self):
        path = self.directory / "columns.pdf"
        with pymupdf.open() as doc:
            page = doc.new_page(width=612, height=792)
            page.insert_text((40, 40), "Two-column research fixture", fontsize=16)
            for name, x in [("LEFT", 40), ("RIGHT", 330)]:
                text = "\n\n".join(f"{name} {i+1}. " + (
                    "This paragraph has enough words to represent an ordinary academic paper. "
                    "We preserve the original order and meaning of every sentence. "
                ) * 3 for i in range(2))
                remaining = page.insert_textbox(pymupdf.Rect(x, 90, x + 240, 730), text, fontsize=10)
                self.assertGreaterEqual(remaining, 0)
            doc.set_metadata({"title": "Embedded fixture title"})
            doc.save(path)
        result = self.read(path)
        offsets = [result["text"].index(label) for label in ["LEFT 1", "LEFT 2", "RIGHT 1", "RIGHT 2"]]
        self.assertEqual(offsets, sorted(offsets))
        self.assertEqual(result["title"], "Embedded fixture title")
        self.assertEqual(len(result["roles"]), len(result["plan"]["units"]))

    def test_unicode_and_equations_are_not_rewritten(self):
        font = Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
        if not font.is_file():
            self.skipTest("System Unicode fixture font unavailable")
        path = self.directory / "unicode.pdf"
        expected = "Café research. α = 3.1 and β = 2.0. Résumé, naïve, São Paulo."
        with pymupdf.open() as doc:
            page = doc.new_page()
            page.insert_font(fontname="fixture", fontfile=str(font))
            page.insert_text((40, 70), expected, fontname="fixture", fontsize=12)
            doc.save(path)
        result = self.read(path)
        self.assertEqual(result["text"], expected)
        self.assertEqual(result["plan"]["units"][0]["edits"], [])

    def test_unreadable_pages_are_reported_without_losing_readable_pages(self):
        path = self.directory / "partly-readable.pdf"
        with pymupdf.open() as doc:
            doc.new_page().insert_text((40, 70), "A readable page keeps the original words.")
            doc.new_page()
            doc.save(path)
        result = self.read(path)
        self.assertIn("A readable page keeps the original words.", result["text"])
        self.assertEqual(result["note"], "2 pages · No readable text on page 2")

    def test_empty_locked_and_damaged_documents_have_actionable_errors(self):
        empty, locked = self.directory / "empty.pdf", self.directory / "locked.pdf"
        with pymupdf.open() as doc:
            doc.new_page()
            doc.save(empty)
            doc.save(locked, encryption=pymupdf.PDF_ENCRYPT_AES_256,
                     owner_pw="owner-fixture", user_pw="reader-fixture")
        with self.assertRaisesRegex(ValueError, "text recognition"):
            self.read(empty)
        with self.assertRaisesRegex(ValueError, "locked"):
            self.read(locked)
        with self.assertRaisesRegex(ValueError, "could not be opened"):
            self.read(b"Not a PDF")


if __name__ == "__main__":
    unittest.main()
