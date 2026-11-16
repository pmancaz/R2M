"""Long-document context must contain the passages relevant to the current question."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from chat_worker import paragraphs, select_passages


class WordTokenizer:
    def encode(self, text, add_special_tokens=False):
        return text.split()


class PassageSelection(unittest.TestCase):
    def setUp(self):
        self.tokenizer = WordTokenizer()

    def test_full_paper_keeps_every_passage_in_original_order(self):
        blocks = ['First passage.', 'A second passage with symbols: α ≤ β.', 'Final passage.']
        selected, mode = select_passages(blocks, 'second', self.tokenizer)
        self.assertEqual(selected, [0, 1, 2])
        self.assertEqual(mode, 'Full paper')

    def test_matching_later_passage_is_not_crowded_out_by_opening(self):
        blocks = ['Opening ' + 'background ' * 12 for _ in range(5)]
        blocks += ['Zebrafish ' + 'important ' * 12]
        blocks += ['Other ' + 'material ' * 12 for _ in range(5)]
        selected, mode = select_passages(blocks, 'What does the paper say about Zebrafish?', self.tokenizer, budget=105)
        self.assertIn(5, selected)
        self.assertEqual(mode, 'Relevant passages from a long document')
        self.assertEqual(selected, sorted(set(selected)))
        self.assertLessEqual(sum(len(self.tokenizer.encode(blocks[i])) + 8 for i in selected), 105)

    def test_query_match_has_priority_over_unrelated_section_anchors(self):
        blocks = ['Abstract ' + 'background ' * 12, 'Discussion ' + 'background ' * 12]
        blocks += ['Opening ' + 'background ' * 12 for _ in range(5)]
        blocks += ['Magnetometers ' + 'calibration ' * 12]
        blocks += ['Conclusions ' + 'general ' * 12 for _ in range(5)]
        selected, _ = select_passages(blocks, 'Explain magnetometers.', self.tokenizer, budget=63)
        self.assertIn(7, selected)
        self.assertLessEqual(sum(len(self.tokenizer.encode(blocks[i])) + 8 for i in selected), 63)

    def test_no_lexical_match_still_supplies_document_opening(self):
        blocks = ['Opening ' + 'background ' * 12 for _ in range(12)]
        selected, _ = select_passages(blocks, 'Summarize the central argument.', self.tokenizer, budget=105)
        self.assertTrue(selected)
        self.assertIn(0, selected)

    def test_oversized_passages_do_not_send_an_empty_reference_paper(self):
        with self.assertRaisesRegex(ValueError, 'shorter paragraphs'):
            select_passages(['oversized ' * 100], 'Explain this.', self.tokenizer, budget=32)

    def test_long_paragraph_chunks_preserve_unicode_text(self):
        text = 'Δείγμα ' * 2000 + '👩🏿‍🚀' * 100 + '\n\nConclusion: α ≤ β.'
        blocks = paragraphs(text)
        self.assertEqual(''.join(''.join(b.split()) for b in blocks), ''.join(text.split()))
        self.assertTrue(all(len(b) <= 6000 for b in blocks))


if __name__ == '__main__':
    unittest.main()
