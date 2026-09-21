"""Offline regressions for evidence integrity and advisory review accounting."""

import argparse
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("rails_bank_runner", ROOT / "runner.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


def store(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value) + "\n")


def answer(question):
    """Use the provider's public shapes, including Score legends and confidence."""
    if question["type"] == "noul":
        return {"type": "noul", "noul": .1}
    if question["type"] == "choice":
        choices = list(question["criteria"])
        return {"type": "choice", "choice": choices[0], "confidence": 1.0,
                "probabilities": {key: float(index == 0) for index, key in enumerate(choices)}}
    return {"type": "score", "score": 0.0, "confidence": 1.0,
            "probabilities": {str(index): float(index == 0)
                              for index in range(len(question["criteria"]))},
            "legend": {str(index): text for index, text in enumerate(question["criteria"])}}


class Response:
    code = 200

    def __init__(self, value):
        self.body = json.dumps(value).encode()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self, maximum):
        return self.body[:maximum]


class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "run"
        self.prior = Path(self.temp.name) / "source"
        self.catalog = json.loads((ROOT / "catalog.json").read_text())
        self.bank = {q["id"]: q for q in self.catalog["questions"]}
        self.case = {
            "id": "case-a", "family": "example", "pair_id": "pair-a",
            "split": "development", "defect": False,
            "path": "app/services/example.rb",
            "changed_paths": ["app/services/example.rb", "spec/example_spec.rb"],
            "base": "base-sha", "head": "candidate-sha",
            "brief": "Return the supplied value without modifying it.",
            "diff": "diff --git a/app/services/example.rb b/app/services/example.rb\n+def call(value) = value\n",
            "target_question_ids": ["coordinator-only-marker"],
        }
        files = {"app/services/example.rb": "class Example\nend\n",
                 "spec/example_spec.rb": "raise unless 1 == 1\n"}
        self.evidence = {
            "freshness": {"state": "current"}, "working_tree": [],
            "checked_out_sha": self.case["head"], "source_files": files,
            "source_hashes": {name: runner.digest(text.encode()) for name, text in files.items()},
            "units": [], "runtime": {}, "relationships": [],
            "generation": 1, "index_checksum": "fixture-index",
        }
        # Any accidental real transport or credential subprocess is a test failure.
        for target in ("urllib.request.AbstractHTTPHandler.do_open",
                       "subprocess.run", "subprocess.check_output"):
            guard = patch(target, side_effect=AssertionError("external operation forbidden"))
            guard.start()
            self.addCleanup(guard.stop)

    def prepare(self, cases=None):
        cases = cases or [self.case]
        store(self.prior / "cases.json", cases)
        for case in cases:
            evidence = copy.deepcopy(self.evidence)
            evidence["checked_out_sha"] = case["head"]
            store(self.prior / "results" / f'{case["id"]}-evidence.json', evidence)
            store(self.prior / "results" / f'{case["id"]}-oracle.json',
                  {"oracle_matches_intended_case": True})
        args = argparse.Namespace(root=str(self.root), prior=str(self.prior), extra=None,
                                  prior_apps=str(self.prior / "apps"))
        with contextlib.redirect_stdout(io.StringIO()):
            runner.prepare(args)
        return runner.read(self.root / "schedule.json")

    def capture(self, transform):
        """Exercise persistence/validation using in-memory provider responses only."""
        self.prepare()
        testcase = self

        class Opener:
            def open(self, request, timeout):
                parsed = json.loads(request.data)
                value = {"model": parsed["model"],
                         "answers": {key: answer(q) for key, q in parsed["questions"].items()},
                         "usage": {"input_tokens": 100, "output_tokens": 10}}
                transform(value)
                return Response(value)

        def opener(*handlers):
            testcase.assertTrue(any(isinstance(h, runner.NoRedirect) for h in handlers))
            proxies = [h for h in handlers if isinstance(h, urllib.request.ProxyHandler)]
            testcase.assertEqual([h.proxies for h in proxies], [{}])
            return Opener()

        with patch.dict(runner.os.environ, {"TYPESAFE_API_KEY": "offline-test-placeholder"}, clear=True), \
                patch.object(runner.urllib.request, "build_opener", side_effect=opener), \
                contextlib.redirect_stdout(io.StringIO()):
            runner.capture(argparse.Namespace(root=str(self.root), credential_command=None))
        return runner.read(self.root / "capture.json")

    def summarize(self):
        with contextlib.redirect_stdout(io.StringIO()):
            runner.summarize(argparse.Namespace(root=str(self.root)))
        return runner.read(self.root / "summary.json")

    def test_choice_allows_bounded_rounding_without_repairing_probabilities(self):
        question = self.bank["disposition"]
        value = {"type": "choice", "choice": "rework", "confidence": .51,
                 "probabilities": {"approve": .20, "simplify": .20, "optimize": .20, "rework": .41}}
        original = copy.deepcopy(value)
        errors, warnings = runner.validate_answer(question, value)
        self.assertEqual(errors, [])
        self.assertIn("distribution_rounding", warnings)
        self.assertEqual(value, original)
        value["probabilities"]["rework"] = .50
        self.assertIn("distribution_sum", runner.validate_answer(question, value)[0])

    def test_choice_cannot_select_a_lower_probability_option(self):
        value = answer(self.bank["disposition"])
        value["choice"] = "rework"
        self.assertIn("choice_not_maximum", runner.validate_answer(self.bank["disposition"], value)[0])

    def test_score_preserves_spectrum_and_rejects_inconsistent_distribution(self):
        question = self.bank["dhh_conformance"]
        value = {"type": "score", "score": 1.8, "confidence": .6,
                 "probabilities": {"0": .10, "1": .20, "2": .50, "3": .20},
                 "legend": {str(i): text for i, text in enumerate(question["criteria"])}}
        self.assertEqual(runner.validate_answer(question, value)[0], [])
        self.assertIsNone(runner.risk(question, value))
        value["score"] = .2
        self.assertIn("score_distribution_mismatch", runner.validate_answer(question, value)[0])

    def test_invalid_probabilities_and_usage_never_become_valid_measurements(self):
        for probability in (True, -0.1, 1.1, float("nan"), float("inf"), 10**1000):
            with self.subTest(probability=str(probability)[:30]):
                self.assertTrue(runner.validate_answer({"type": "noul"},
                                                      {"type": "noul", "noul": probability})[0])
        for counter in (True, -1, 10**9 + 1, "100", None, float("nan")):
            with self.subTest(counter=counter):
                self.assertFalse(runner.valid_usage({"input_tokens": counter, "output_tokens": 1}))

    def test_packet_keeps_all_changed_files_and_omits_coordinator_labels(self):
        state, _ = runner.packet(self.case, self.evidence, self.catalog)
        self.assertEqual(state["changed"], self.case["changed_paths"])
        self.assertIn("spec/example_spec.rb", state["tests"])
        self.assertNotIn("coordinator-only-marker", runner.encoded(state).decode())
        self.assertNotIn("defect", state)

    def test_changed_or_missing_source_is_rejected(self):
        altered = copy.deepcopy(self.evidence)
        altered["source_files"][self.case["path"]] += "# changed after extraction\n"
        with self.assertRaisesRegex(ValueError, "source_hash"):
            runner.packet(self.case, altered, self.catalog)
        missing = copy.deepcopy(self.evidence)
        del missing["source_files"]["spec/example_spec.rb"]
        with self.assertRaisesRegex(ValueError, "missing_changed_source"):
            runner.packet(self.case, missing, self.catalog)

    def test_unknown_runtime_does_not_become_supplied_evidence(self):
        _, ledger = runner.packet(self.case, self.evidence, self.catalog)
        for key in ("rails_version", "queue_adapter", "enqueue_after_transaction_commit", "schema"):
            self.assertNotEqual(ledger["requirements"][key]["status"], "supplied", key)
        self.assertNotEqual(ledger["questions"]["job_enqueued_inside_transaction"]["status"], "supplied")

    def test_null_runtime_setting_is_unknown_even_when_job_is_present(self):
        evidence = copy.deepcopy(self.evidence)
        evidence["runtime"] = {"rails_version": None, "active_job_adapter": None,
                               "delivery_job_enqueue_after_transaction_commit": None}
        evidence["units"] = [{"identifier": "ReviewDeliveryJob", "type": "job"}]
        _, ledger = runner.packet(self.case, evidence, self.catalog)
        for key in ("rails_version", "queue_adapter", "enqueue_after_transaction_commit"):
            self.assertNotEqual(ledger["requirements"][key]["status"], "supplied", key)

    def test_prepare_normalizes_development_and_preserves_holdout_state_pairing(self):
        holdout = {**self.case, "id": "case-b", "split": "holdout"}
        schedule = self.prepare([self.case, holdout])
        self.assertEqual({row["split"] for row in schedule}, {"train", "holdout"})
        for case in (self.case, holdout):
            rows = [row for row in schedule if row["case_id"] == case["id"]]
            self.assertEqual({row["arm"] for row in rows}, {"bank", "baseline"})
            self.assertEqual({row["repeat"] for row in rows}, {0, 1, 2})
            self.assertEqual(len({row["state_sha256"] for row in rows}), 1)
        for row in schedule:
            self.assertEqual(runner.digest((self.root / row["request"]).read_bytes()), row["sha256"])

    def test_unknown_split_fails_before_capture(self):
        with self.assertRaisesRegex(ValueError, "unknown_split"):
            self.prepare([{**self.case, "split": "typo"}])

    def test_modified_frozen_catalog_or_ledger_is_rejected(self):
        self.prepare()
        for relative in ("catalog.json", "ledgers/case-a.json", "protocol.md"):
            path = self.root / relative
            original = path.read_bytes()
            path.write_bytes(original + b" ")
            with self.subTest(path=relative), self.assertRaisesRegex(ValueError, "frozen_input_changed"):
                runner.verify_inputs(self.root)
            path.write_bytes(original)
        runner.verify_inputs(self.root)

    def test_redirect_refuses_to_forward_an_authorization_header(self):
        request = urllib.request.Request("https://api.typesafe.ai/v1/systemone",
                                         data=b"{}", headers={"Authorization": "Bearer placeholder"})
        with self.assertRaises(urllib.error.HTTPError) as caught:
            runner.NoRedirect().redirect_request(request, None, 302, "Found", {},
                                                 "https://example.invalid/collect")
        caught.exception.close()

    def test_invalid_usage_is_preserved_as_unknown_without_poisoning_capture(self):
        capture = self.capture(lambda value: value["usage"].update(input_tokens=float("nan")))
        self.assertTrue(capture["attempts"])
        self.assertTrue(all(row["status"] != "valid" for row in capture["attempts"]))
        self.assertTrue(all(not runner.valid_usage(row.get("usage")) for row in capture["attempts"]))
        summary = self.summarize()
        self.assertEqual(summary["unknown_usage_attempts"], len(capture["attempts"]))
        self.assertEqual(summary["usage"], {"input_tokens": 0, "output_tokens": 0})
        for path in self.root.rglob("*"):
            if path.is_file():
                self.assertNotIn(b"offline-test-placeholder", path.read_bytes())

    def test_unexpected_answer_id_cannot_be_a_fully_valid_capture(self):
        capture = self.capture(lambda value: value["answers"].update(
            unexpected={"type": "noul", "noul": .1}))
        self.assertTrue(all(row["status"] != "valid" for row in capture["attempts"]))

    def test_altered_response_bytes_are_rejected_during_summarization(self):
        capture = self.capture(lambda value: None)
        path = self.root / capture["attempts"][0]["response"]
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(ValueError, "response_changed"):
            self.summarize()

    def test_high_headline_score_does_not_enter_defect_shortlist(self):
        def maximal_score(value):
            score = value["answers"].get("dhh_conformance")
            if score:
                score.update(score=3.0, probabilities={"0": 0.0, "1": 0.0, "2": 0.0, "3": 1.0})
        self.capture(maximal_score)
        summary = self.summarize()
        report = next(row for row in summary["reports"] if row["arm"] == "bank")
        self.assertIsNone(report["judgments"]["dhh_conformance"]["risk"])
        self.assertNotIn("dhh_conformance", report["shortlist"])
        self.assertLess(report["priority"], .5)

    def test_two_valid_repeats_remain_unassessed_instead_of_becoming_a_shortlist(self):
        seen = []

        def omit_one_repeat(value):
            if "ar_unchecked_save" in value["answers"]:
                seen.append(True)
                if len(seen) == 1:
                    del value["answers"]["ar_unchecked_save"]
                else:
                    value["answers"]["ar_unchecked_save"]["noul"] = .95

        capture = self.capture(omit_one_repeat)
        self.assertEqual(len(seen), 3)
        self.assertEqual(sum(row["status"] == "partial_invalid" for row in capture["attempts"]), 1)
        summary = self.summarize()
        report = next(row for row in summary["reports"] if row["arm"] == "bank")
        judgment = report["judgments"]["ar_unchecked_save"]
        self.assertEqual(judgment["valid_repeats"], 2)
        self.assertFalse(judgment["complete_repeats"])
        self.assertIn("ar_unchecked_save", report["unassessed"])
        self.assertNotIn("ar_unchecked_save", report["shortlist"])


if __name__ == "__main__":
    unittest.main()
