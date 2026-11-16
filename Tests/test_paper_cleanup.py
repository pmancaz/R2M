"""Protect author text from cleanup heuristics; these tests require no AI weights."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
from paper import make_plan, reference_entry


def edited(unit, group):
    raw = unit["raw"].encode("utf-16-le")
    for edit in sorted((e for e in unit["edits"] if e["group"] == group), key=lambda e: e["at"], reverse=True):
        start, stop = edit["at"] * 2, (edit["at"] + edit["length"]) * 2
        raw = raw[:start] + edit["replacement"].encode("utf-16-le") + raw[stop:]
    return raw.decode("utf-16-le")


class AuthorTextPreservation(unittest.TestCase):
    def plan(self, text, title="", roles=None):
        return make_plan(text, title, None, lambda message: None, roles)["units"]

    def test_footnotes_do_not_remove_decimal_or_version_suffixes(self):
        paragraph = "The mean was 3.1 and the error was 2.12 in version 1.2. Results were stable.1"
        units = self.plan(paragraph + "\n\n>1 First footnote.\n\n>2 Second footnote.\n\n>12 Twelfth footnote.")
        self.assertEqual(edited(units[0], "cleanup"), paragraph[:-1])
        self.assertEqual(edited(units[1], "cleanup"), "First footnote.")

    def test_prose_with_dates_is_not_a_reference_entry(self):
        for paragraph in [
            "In 2024, we repeated the analysis without measurement error.",
            "Smith observed in 2024, that measurements were inconsistent.",
            "After 2023, the results changed.",
            "Our findings in 2024, however, showed a different trend.",
        ]:
            with self.subTest(paragraph=paragraph):
                units = self.plan("References\n\nLatour, B. (1994). On technical mediation.\n\n" + paragraph)
                self.assertEqual(units[0].get("group"), "references")
                self.assertEqual(units[1].get("group"), "references")
                self.assertNotIn("reason", units[2])

    def test_reference_styles_remain_recognized(self):
        for paragraph in [
            "Latour, B. (1994). On technical mediation.",
            "Bruno Latour. 1994. On technical mediation.",
            "World Health Organization (2024). Annual report.",
            "The Royal Society (2020). Report on science.",
            "van der Berg, J. (2021). An article.",
            "Émile Durkheim (1893). De la division du travail social.",
            "Smith, J. and Jones, A. (2021). Another article.",
            "[1] A reference without a date.",
        ]:
            with self.subTest(paragraph=paragraph):
                self.assertTrue(reference_entry(paragraph))

    def test_unicode_citation_spans_use_utf16_without_changing_author_words(self):
        paragraph = "An 🧪 observation (Latour, 1994) supports café research and α = 3.1."
        units = self.plan(paragraph + "\n\nReferences\n\nLatour, B. (1994). Technical mediation.")
        self.assertEqual(edited(units[0], "references"), "An 🧪 observation supports café research and α = 3.1.")
        self.assertEqual(units[0]["raw"], paragraph)

    def test_math_and_formula_blocks_are_preserved(self):
        paragraph = "P(X = 1) = α × 3.1 + β (Smith, 2020)"
        units = self.plan(paragraph, roles=["formula"])
        self.assertEqual(units[0]["raw"], paragraph)
        self.assertEqual(units[0]["edits"], [])
        self.assertNotIn("reason", units[0])

    def test_explicit_publisher_notices_are_removed_and_metadata_retained(self):
        units = self.plan("Paper title\n\nJane Author\n\nEmail alerts: click here\n\nAbstract\n\nThis paper explores how groups share meaning.", "Paper title")
        self.assertNotIn("reason", units[0])
        self.assertNotIn("reason", units[1])
        self.assertEqual(units[2]["reason"], "Publisher service notice")
        self.assertNotIn("reason", units[4])

    def test_appendix_after_references_is_retained(self):
        units = self.plan("References\n\nLatour, B. (1994). Technical mediation.\n\nAppendix A: Further analysis\n\nIn 2024, we repeated the experiment.")
        self.assertEqual(units[1].get("group"), "references")
        self.assertNotIn("reason", units[2])
        self.assertNotIn("reason", units[3])


if __name__ == "__main__":
    unittest.main()
