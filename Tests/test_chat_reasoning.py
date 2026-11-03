"""Reasoning must finish naturally or be discarded before a clean answer pass."""
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
from chat_worker import generate_answer, visible_answer


def item(text, count, token=None, finish_reason=None):
    return SimpleNamespace(text=text, generation_tokens=count, token=token, finish_reason=finish_reason)


class ReasoningBoundary(unittest.TestCase):
    def test_natural_completion_streams_only_final_answer(self):
        calls, updates, closed = [], [], []
        def make_stream(reasoning):
            calls.append(reasoning)
            try:
                yield item("PRIVATE reasoning", 1)
                yield item("</think>", 2)
                yield item("The author treats instruments as tools for thought [P2].", 3, finish_reason="stop")
            finally:
                closed.append(reasoning)
        answer, _, limited = generate_answer(make_stream, True, lambda s,a: updates.append(a))
        self.assertEqual(calls, [True])
        self.assertEqual(closed, [True])
        self.assertIn("tools for thought", answer)
        self.assertFalse(limited)
        self.assertTrue(all("PRIVATE" not in value for value in updates))

    def test_budget_exhaustion_discards_unfinished_scratch_and_closes_first(self):
        calls, updates, events = [], [], []
        def make_stream(reasoning):
            calls.append(reasoning)
            if not reasoning:
                self.assertEqual(events, ["private stream closed"])
            try:
                if reasoning:
                    yield item("PRIVATE outline", 1)
                    yield item("PRIVATE unfinished plan", 3)
                    self.fail("The private stream was consumed past its budget")
                else:
                    yield item("Clean explanation [P3].", 1, finish_reason="stop")
            finally:
                events.append("private stream closed" if reasoning else "answer stream closed")
        answer, _, limited = generate_answer(make_stream, True, lambda s,a: updates.append(a), reasoning_budget=3)
        self.assertEqual(calls, [True, False])
        self.assertEqual(answer, "Clean explanation [P3].")
        self.assertFalse(limited)
        self.assertTrue(all("PRIVATE" not in value for value in updates))

    def test_early_stop_without_final_answer_also_uses_clean_pass(self):
        calls = []
        def make_stream(reasoning):
            calls.append(reasoning)
            yield item("PRIVATE stopped" if reasoning else "Final answer.", 1, finish_reason="stop")
        answer, _, _ = generate_answer(make_stream, True, lambda *_:None)
        self.assertEqual(calls, [True, False])
        self.assertEqual(answer, "Final answer.")

    def test_natural_close_at_budget_is_accepted(self):
        calls = []
        def make_stream(reasoning):
            calls.append(reasoning)
            yield item("PRIVATE", 1)
            yield item("</think>Final answer.", 3, finish_reason="stop")
        answer, _, _ = generate_answer(make_stream, True, lambda *_:None, reasoning_budget=3)
        self.assertEqual(calls, [True])
        self.assertEqual(answer, "Final answer.")

    def test_nonthinking_stream_never_leaks_split_reasoning_tags(self):
        updates = []
        def make_stream(reasoning):
            self.assertFalse(reasoning)
            for n,text in enumerate(["<thi", "nk>PRIVATE", " notes</thi", "nk>Final answer."], 1):
                yield item(text, n)
        answer, _, _ = generate_answer(make_stream, False, lambda s,a:updates.append(a))
        self.assertEqual(answer, "Final answer.")
        self.assertTrue(all("PRIVATE" not in value and "<thi" not in value for value in updates))
        self.assertEqual(visible_answer("<think>PRIVATE never closes"), "")

    def test_separate_final_answer_budget_is_enforced(self):
        def make_stream(reasoning):
            yield item("PRIVATE</think>", 2)
            yield item("Final answer", 5)
            self.fail("Answer stream exceeded its own token budget")
        answer, _, limited = generate_answer(make_stream, True, lambda *_:None, answer_budget=3)
        self.assertEqual(answer, "Final answer")
        self.assertTrue(limited)


if __name__ == "__main__":
    unittest.main()
