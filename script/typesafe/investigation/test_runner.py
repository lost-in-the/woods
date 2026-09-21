"""Offline contract tests for the prospective evidence-selection pilot."""
import argparse
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("investigation_runner_under_test", HERE / "runner.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class FakeResponse:
    code = 200

    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, size):
        return self.body[:size]


def answer_for(question):
    if question["type"] == "noul":
        return {"type": "noul", "noul": .2}
    criteria = question["criteria"]
    keys = list(criteria) if question["type"] == "choice" else [str(i) for i in range(len(criteria))]
    result = {"type": question["type"], "confidence": .9,
              "probabilities": {key: float(i == 0) for i, key in enumerate(keys)}}
    if question["type"] == "choice":
        result["choice"] = keys[0]
    else:
        result.update(score=0, legend={key: criteria[int(key)] for key in keys})
    return result


class InvestigationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.fixture = Path(self.temp.name) / "fixtures"
        self.root = Path(self.temp.name) / "capture"
        self.source = "class PriceCalculator\n  def call(amount)\n    PricePolicy.round(amount)\n  end\nend\n"
        self.cards = []
        for card_id, path in (("card_c", "app/services/price_policy.rb"),
                              ("card_a", "app/models/purchase.rb"),
                              ("card_b", "config/initializers/calendar.rb")):
            source = f"# UNOPENED_{card_id}\nclass SupportingCode; end\n"
            self.cards.append({"id": card_id, "path": path, "source": source,
                               "sha256": runner.digest(source.encode()), "kind": "source",
                               "private_note": "PRIVATE_CARD_METADATA"})
        self.case = {"id": "case-a", "path": "app/services/price_calculator.rb",
                     "changed_paths": ["app/services/price_calculator.rb"],
                     "brief": "Round the amount according to the configured policy.",
                     "diff": "+ PricePolicy.round(amount)\n", "base": "base-private-sha", "head": "head-private-sha",
                     "cards": self.cards, "defect": "PRIVATE_ORACLE_LABEL", "family": "PRIVATE_FAMILY",
                     "necessary_card_ids": ["card_c"]}
        sources = {self.case["path"]: self.source, **{c["path"]: c["source"] for c in self.cards}}
        self.evidence = {"source_files": sources,
                         "source_hashes": {path: runner.digest(source.encode()) for path, source in sources.items()},
                         "runtime": {"rails_version": "7.2.3", "ruby_version": "3.3.0", "database_adapter": "SQLite",
                                     "active_job_adapter": "test", "time_zone": "PRIVATE_RUNTIME_PREMISE",
                                     "oracle_matches_intended_case": "PRIVATE_EXECUTION_RESULT"},
                         "freshness": {"state": "current", "captured_at": "2026-09-21T12:00:00Z"},
                         "working_tree": [], "checked_out_sha": self.case["head"], "generation": "generation-a",
                         "index_checksum": "index-checksum", "manifest": {"generation_token": "generation-token"},
                         "units": [{"source_code": "PRIVATE_UNOPENED_UNIT"}],
                         "relationships": [{"private": "PRIVATE_GRAPH"}]}

    def prepare(self, case=None, evidence=None):
        case, evidence = case or self.case, evidence or self.evidence
        runner.write(self.fixture / "cases.json", [case])
        runner.write(self.fixture / "results" / f'{case["id"]}-evidence.json', evidence)
        runner.write(self.fixture / "results" / f'{case["id"]}-oracle.json',
                     {"oracle_matches_intended_case": True, "result": "PRIVATE_EXECUTABLE_RECEIPT"})
        with contextlib.redirect_stdout(io.StringIO()):
            runner.prepare(argparse.Namespace(root=str(self.root), fixtures=str(self.fixture)))

    def run_capture(self, mutate=None):
        requests = []

        def respond(request, timeout):
            value = json.loads(request.data)
            requests.append(value)
            result = {"model": runner.MODEL, "usage": {"input_tokens": 100, "output_tokens": 10},
                      "answers": {qid: answer_for(q) for qid, q in value["questions"].items()}}
            if mutate:
                mutate(value, result)
            return FakeResponse(json.dumps(result).encode())

        opener = mock.Mock()
        opener.open.side_effect = respond
        with mock.patch.object(runner.urllib.request, "build_opener", return_value=opener), \
                mock.patch.dict(runner.os.environ, {"TYPESAFE_API_KEY": "offline-test-placeholder"}), \
                contextlib.redirect_stdout(io.StringIO()):
            runner.capture(argparse.Namespace(root=str(self.root)))
        return runner.read(self.root / "capture.json"), runner.read(self.root / "summary.json"), requests

    def test_initial_state_exposes_menu_but_no_support_body_or_private_metadata(self):
        state = runner.initial_state(self.case, self.evidence)
        serialized = json.dumps(state)
        self.assertEqual([c["path"] for c in state["observed_source"]], self.case["changed_paths"])
        self.assertEqual(len(state["available_sources"]), 3)
        self.assertEqual(state["premises"]["rails_version"], "7.2.3")
        for secret in ("UNOPENED_", "PRIVATE_", "base-private-sha", "head-private-sha", "necessary_card_ids"):
            self.assertNotIn(secret, serialized)
        self.assertNotIn("schema", runner.supplied_requirements(state))
        self.assertNotIn("callers", runner.supplied_requirements(state))

    def test_static_policy_depends_only_on_touched_source_and_menu(self):
        state = runner.initial_state(self.case, self.evidence)
        expected = runner.static_select(state, self.cards)
        self.assertEqual(expected[0], "card_c")
        altered = copy.deepcopy(self.cards)
        for card in altered:
            card["source"] = "PricePolicy " * 50
            card["necessary"] = True
            card["private_note"] = "opposite oracle outcome"
        self.assertEqual(runner.static_select(state, altered[::-1]), expected)
        self.assertEqual(len(expected), 2)

    def test_observation_is_nonmutating_and_location_choices_are_observed_only(self):
        initial = runner.initial_state(self.case, self.evidence)
        snapshot = copy.deepcopy(initial)
        observed = runner.observe(initial, self.cards[0])
        self.assertEqual(initial, snapshot)
        self.assertEqual(set(runner.focus_questions(initial)["evidence"]["criteria"]), {"changed0", "none"})
        self.assertEqual(set(runner.focus_questions(observed)["evidence"]["criteria"]), {"changed0", "card_c", "none"})
        self.assertNotIn("PRIVATE_CARD_METADATA", json.dumps(observed))
        with self.assertRaisesRegex(ValueError, "duplicate_inspection"):
            runner.observe(observed, self.cards[0])

    def test_second_routing_choice_excludes_previously_opened_card(self):
        state = runner.observe(runner.initial_state(self.case, self.evidence), self.cards[0])
        payload = runner.routing_request(state, [], self.cards, ["card_c"])
        self.assertEqual(payload["state"]["inspection_budget_remaining"], 1)
        self.assertEqual(set(payload["questions"]["next_source"]["criteria"]),
                         {"card_a", "card_b", "stop", "need_context"})
        self.assertNotIn("UNOPENED_card_a", json.dumps(payload))
        self.assertNotIn("PRIVATE_CARD_METADATA", json.dumps(payload))

    def test_cards_reject_wrong_hash_reserved_ids_and_traversal(self):
        for field, value, error in (("sha256", "bad", "card_hash"), ("id", "stop", "card_identifier"),
                                    ("path", "../secret.rb", "card_path"), ("path", "/private.rb", "card_path")):
            case = copy.deepcopy(self.case)
            case["cards"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, error):
                runner.safe_cards(case)

    def test_scan_hints_respect_type_kind_direction_and_evidence_requirements(self):
        state = runner.initial_state(self.case, self.evidence)
        base = {"type": "noul", "kind": "defect", "direction": "yes_is_bad", "section": "active_record",
                "instructions": "A bounded question", "context_requirements": ["diff", "touched_source"]}
        rows = [{**base, "id": "supplied"}, {**base, "id": "inverse", "direction": "yes_is_good"},
                {**base, "id": "no_schema", "context_requirements": ["schema"]},
                {**base, "id": "no_callers", "context_requirements": ["callers"]},
                {**base, "id": "convention", "kind": "convention"},
                {**base, "id": "dimension", "type": "score"},
                {**base, "id": "not_a_test", "section": "tests"},
                {**base, "id": "not_a_view", "section": "views"}, {**base, "id": "invalid"}]
        response = {"answers": {q["id"]: {"noul": .9} for q in rows}}
        validation = {"questions": {q["id"]: {"valid": q["id"] != "invalid"} for q in rows}}
        hints = runner.scan_hints(state, {"questions": rows}, response, validation)
        self.assertEqual([h["id"] for h in hints], ["supplied", "inverse"])
        self.assertAlmostEqual(hints[1]["directed_probability"], .1)

    def test_high_lead_preserves_missing_context_without_claiming_confirmation(self):
        questions = runner.focus_questions(runner.initial_state(self.case, self.evidence))
        answers = {qid: answer_for(q) for qid, q in questions.items()}
        answers["contract_violation"]["noul"] = .95
        answers["context_missing"]["noul"] = .99
        validation = {"questions": {qid: {"valid": True} for qid in questions}}
        result = runner.lead_receipt(answers, validation)
        self.assertTrue(result["raw_high_lead"])
        self.assertEqual(result["missing_context_probability"], .99)
        self.assertEqual(result["status"], "assessed_judgments_not_confirmed")
        for mechanism in ("none", "unknown"):
            negative = copy.deepcopy(answers)
            negative["mechanism"]["choice"] = mechanism
            self.assertFalse(runner.lead_receipt(negative, validation)["raw_high_lead"])
        validation["questions"]["evidence"]["valid"] = False
        self.assertEqual(runner.lead_receipt(answers, validation)["status"], "unassessed_invalid_answer")

    def test_prepare_freezes_all_questions_shared_scan_and_balanced_arm_order(self):
        self.prepare()
        schedule = runner.read(self.root / "schedule.json")
        self.assertEqual({job["repeat"] for job in schedule}, {0, 1})
        self.assertEqual({tuple(job["arm_order"]) for job in schedule},
                         {("static", "adaptive"), ("adaptive", "static")})
        scan = runner.read(self.root / "scan-requests" / "case-a.json")
        self.assertEqual(len(scan["questions"]), 204)
        self.assertEqual(scan["model"], "jev-1.13.0")
        self.assertEqual(runner.read(self.root / "preflight.json")["maximum_calls"], 10)
        runner.bank.verify_inputs(self.root)
        path = self.root / "cards" / "case-a.json"
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(ValueError, "frozen_input_changed"):
            runner.bank.verify_inputs(self.root)

    def test_private_oracle_and_generation_receipts_are_frozen_without_entering_state(self):
        self.prepare()
        freeze = runner.read(self.root / "input-freeze.json")
        self.assertIn("coordinator-oracles/case-a.json", freeze)
        self.assertIn("coordinator-evidence/case-a.json", freeze)
        ledger = runner.read(self.root / "ledgers" / "case-a.json")
        self.assertEqual(ledger["generation_token"], "generation-token")
        self.assertEqual(ledger["index_checksum"], "index-checksum")
        self.assertEqual(ledger["freshness"], self.evidence["freshness"])
        initial = (self.root / "scan-requests" / "case-a.json").read_text()
        self.assertNotIn("PRIVATE_EXECUTABLE_RECEIPT", initial)
        path = self.root / "coordinator-oracles" / "case-a.json"
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(ValueError, "frozen_input_changed"):
            runner.bank.verify_inputs(self.root)

    def test_changed_validation_or_applicability_dependency_refuses_before_capture(self):
        self.prepare()
        alternate = Path(self.temp.name) / "alternate-bank"
        alternate.mkdir()
        for changed in ("runner.py", "presentation.py"):
            for name in ("runner.py", "presentation.py"):
                body = (runner.BANK_DIR / name).read_bytes()
                (alternate / name).write_bytes(body + (b"\n# changed\n" if name == changed else b""))
            with self.subTest(dependency=changed), mock.patch.object(runner, "BANK_DIR", alternate), \
                    mock.patch.object(runner.urllib.request, "build_opener") as opener:
                with self.assertRaisesRegex(ValueError, "dependency_changed_after_freeze"):
                    runner.capture(argparse.Namespace(root=str(self.root)))
                opener.assert_not_called()
                self.assertFalse((self.root / "capture.json").exists())

    def test_preflight_rejects_an_oversized_possible_selection_before_capture(self):
        case, evidence = copy.deepcopy(self.case), copy.deepcopy(self.evidence)
        for card in case["cards"]:
            card["source"] = "x" * 8_000
            card["sha256"] = runner.digest(card["source"].encode())
            evidence["source_files"][card["path"]] = card["source"]
            evidence["source_hashes"][card["path"]] = card["sha256"]
        with self.assertRaisesRegex(ValueError, "state_budget_exceeded_no_truncation"):
            self.prepare(case, evidence)
        self.assertFalse((self.root / "capture.json").exists())
        self.assertFalse((self.root / "input-freeze.json").exists())

    def test_stale_evidence_is_rejected_before_a_freeze_is_published(self):
        evidence = copy.deepcopy(self.evidence)
        evidence["freshness"]["state"] = "stale"
        with self.assertRaisesRegex(ValueError, "identity_or_freshness"):
            self.prepare(evidence=evidence)
        self.assertFalse((self.root / "input-freeze.json").exists())

    def test_mock_capture_counts_shared_scan_once_and_bounds_unique_inspections(self):
        self.prepare()
        capture, summary, requests = self.run_capture()
        self.assertEqual(len(capture["attempts"]), 10)
        self.assertEqual(summary["usage"], {"input_tokens": 1000, "output_tokens": 100})
        self.assertEqual(summary["by_arm_actual"]["shared"]["attempts"], 2)
        self.assertEqual(len([r for r in requests if len(r["questions"]) == 204]), 2)
        self.assertEqual(sum(v["usage"]["input_tokens"] for v in summary["by_arm_actual"].values()), 1000)
        self.assertTrue(capture["finished"])
        for job in capture["jobs"]:
            for arm in job["arms"].values():
                self.assertEqual(len(arm["selected"]), 2)
                self.assertEqual(len(set(arm["selected"])), 2)
        for request in requests:
            self.assertNotIn("PRIVATE_", json.dumps(request))
        for path in self.root.rglob("*"):
            if path.is_file():
                self.assertNotIn(b"offline-test-placeholder", path.read_bytes())

    def test_invalid_route_does_not_inspect_a_card_or_retry(self):
        self.prepare()

        def invalidate_route(request, result):
            if "next_source" in request["questions"]:
                result["answers"]["next_source"]["choice"] = "not_offered"

        capture, summary, _ = self.run_capture(invalidate_route)
        self.assertEqual(len(capture["attempts"]), 8)
        for job in capture["jobs"]:
            arm = job["arms"]["adaptive"]
            self.assertEqual(arm["selected"], [])
            self.assertEqual(arm["stop"], "invalid_route")
            self.assertEqual(arm["observed_ids"], ["changed0"])
        self.assertEqual(summary["by_arm_actual"]["adaptive"]["attempts"], 4)

    def test_stop_is_recorded_with_zero_inspections_and_no_second_route(self):
        self.prepare()

        def stop(request, result):
            if "next_source" in request["questions"]:
                answer = result["answers"]["next_source"]
                answer["choice"] = "stop"
                answer["probabilities"] = {key: float(key == "stop") for key in answer["probabilities"]}

        capture, _, _ = self.run_capture(stop)
        self.assertEqual(len(capture["attempts"]), 8)
        self.assertTrue(all(j["arms"]["adaptive"]["stop"] == "stop" for j in capture["jobs"]))
        self.assertTrue(all(j["arms"]["adaptive"]["selected"] == [] for j in capture["jobs"]))

    def test_unknown_usage_remains_unknown_and_preserves_attempt_denominator(self):
        self.prepare()

        def malformed_usage(_, result):
            result["usage"]["input_tokens"] = -1

        capture, summary, _ = self.run_capture(malformed_usage)
        self.assertEqual(summary["unknown_usage_attempts"], len(capture["attempts"]))
        self.assertEqual(summary["usage"], {"input_tokens": 0, "output_tokens": 0})
        self.assertTrue(all(row["status"] == "error" for row in capture["attempts"]))
        self.assertTrue(all(j["arms"]["adaptive"]["stop"] == "invalid_route" for j in capture["jobs"]))
        self.assertTrue(all(a["lead"]["status"] == "unassessed_invalid_answer"
                            for j in capture["jobs"] for a in j["arms"].values()))

    def test_summary_refuses_altered_response_bytes(self):
        self.prepare()
        capture, _, _ = self.run_capture()
        path = self.root / capture["attempts"][0]["response"]
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(ValueError, "response_tamper"):
            runner.summarize(self.root)

    def test_unfinished_capture_keeps_planned_jobs_visible(self):
        self.prepare()
        runner.Capture(self.root, "offline-test-placeholder")
        with contextlib.redirect_stdout(io.StringIO()):
            runner.summarize(self.root)
        summary = runner.read(self.root / "summary.json")
        self.assertFalse(summary["finished"])
        self.assertEqual(summary["planned_jobs"], 2)
        self.assertEqual(summary["completed_jobs"], 0)
        self.assertEqual(summary["unfinished_jobs"], [{"case_id": "case-a", "repeat": i} for i in (0, 1)])

    def test_persisted_started_attempt_has_unknown_latency_and_is_not_dropped(self):
        self.prepare()
        capture = runner.Capture(self.root, "offline-test-placeholder")
        state = runner.initial_state(self.case, self.evidence)
        request_path = self.root / "requests" / "interrupted-route.json"
        runner.write(request_path, runner.routing_request(state, [], self.cards, []))
        capture.run["attempts"].append({
            "id": "interrupted-route", "case_id": "case-a", "repeat": 0,
            "arm": "adaptive", "stage": "route", "status": "started",
            "request": "requests/interrupted-route.json",
            "request_sha256": runner.digest(request_path.read_bytes()),
        })
        runner.write(capture.path, capture.run)
        with contextlib.redirect_stdout(io.StringIO()):
            runner.summarize(self.root)
        summary = runner.read(self.root / "summary.json")
        self.assertEqual(summary["attempts"], 1)
        self.assertEqual(summary["unknown_usage_attempts"], 1)
        self.assertEqual(summary["unknown_latency_attempts"], 1)
        self.assertEqual(summary["request_seconds_sum"], 0)
        self.assertEqual(summary["by_arm_actual"]["adaptive"]["attempts"], 1)
        self.assertEqual(summary["by_arm_actual"]["adaptive"]["unknown_latency_attempts"], 1)
        self.assertEqual(summary["by_arm_actual"]["adaptive"]["request_seconds_sum"], 0)
        self.assertEqual(summary["completed_jobs"], 0)
        self.assertEqual(len(summary["unfinished_jobs"]), 2)


if __name__ == "__main__":
    unittest.main()
