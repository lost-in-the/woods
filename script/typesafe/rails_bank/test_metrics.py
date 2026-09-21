"""Offline behavioral checks for the comparative bank metrics."""

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


MODULE = Path(__file__).with_name("metrics.py")
spec = importlib.util.spec_from_file_location("rails_bank_metrics", MODULE)
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)


def question(qid, kind="defect", direction="yes_is_bad", typ="noul"):
    q = {"id": qid, "type": typ, "kind": kind, "direction": direction}
    if typ == "score":
        q["criteria"] = ["absent", "low", "medium", "high"]
    return q


def judgment(value=.9, *, status="supplied", repeats=3, typ="noul"):
    raw = [{"type": typ, typ: value} for _ in range(repeats)]
    return {"type": typ, "raw": raw, "valid_repeats": repeats,
            "expected_repeats": 3, "complete_repeats": repeats == 3,
            "risk": value, "evidence": {"status": status,
            "missing": {"siblings": {"status": "unknown"}} if status != "supplied" else {}}}


def fixture():
    catalog = {"bank_version": "test-bank", "interpretation_version": "test-meta",
               "questions": [question("target"), question("incidental"),
                             question("style", "convention"), question("fact", "fact"),
                             question("visibility", typ="score")]}
    cases = [{"id": "a", "family": "sample", "pair_id": "p", "split": "train",
              "defect": True, "target_question_ids": ["target"],
              "app_path": "/home/private/person/app"},
             {"id": "b", "family": "sample", "pair_id": "p", "split": "train",
              "defect": False, "target_question_ids": ["target"]}]
    reports = []
    for case in cases:
        for arm in ("bank", "baseline"):
            js = {"target": judgment(.9 if case["defect"] else .1)} if arm == "bank" else {
                "correctness": judgment(.7 if case["defect"] else .2)}
            reports.append({"case_id": case["id"], "arm": arm,
                            "split": "train", "judgments": js})
    return catalog, cases, {"reports": reports}, {"attempts": []}


def run_fixture(data):
    catalog, cases, summary, capture = data
    return metrics.build_metrics(summary, cases, capture, catalog)


class MetricsTest(unittest.TestCase):
    def test_all_raw_high_signals_survive_kind_and_evidence_exclusion(self):
        data = fixture()
        js = data[2]["reports"][0]["judgments"]
        js.update(incidental=judgment(.95, status="unknown"), style=judgment(.99),
                  fact=judgment(.91), visibility=judgment(3, typ="score"))
        result = run_fixture(data)
        case = next(c for c in result["candidates"] if c["case_id"] == "a" and c["arm"] == "bank")
        signals = {s["question_id"]: s for s in case["high_signals"]}
        self.assertEqual(set(signals), {"target", "incidental", "style", "fact"})
        self.assertEqual(signals["incidental"]["evidence_status"], "unknown")
        self.assertEqual(signals["style"]["kind"], "convention")
        self.assertFalse(signals["style"]["eligible_defect_check"])
        self.assertFalse(signals["incidental"]["eligible_defect_check"])
        self.assertEqual(case["priority"], .9)
        self.assertEqual(case["intended_mechanism_signal"], True)

    def test_partial_repeats_are_visible_and_ineligible(self):
        data = fixture()
        data[2]["reports"][0]["judgments"]["target"] = judgment(.99, repeats=1)
        result = run_fixture(data)
        case = next(c for c in result["candidates"] if c["case_id"] == "a" and c["arm"] == "bank")
        self.assertIsNone(case["priority"])
        self.assertFalse(case["intended_mechanism_signal"])
        self.assertEqual(case["high_signals"][0]["valid_repeats"], 1)
        self.assertEqual(case["targets"][0]["status"], "incomplete_repeats")

    def test_not_applicable_is_neither_assessed_nor_missing_and_keeps_original_ledger(self):
        data = fixture()
        original = {"status": "supplied", "missing": {}}
        j = judgment(.99, status="not_applicable")
        j["evidence"] = {"status": "not_applicable", "missing": {}, "reason": "No changed views"}
        j["original_evidence"] = original
        data[2]["reports"][0]["judgments"]["target"] = j
        result = run_fixture(data)
        case = next(c for c in result["candidates"] if c["case_id"] == "a" and c["arm"] == "bank")
        self.assertEqual(case["question_checks_not_applicable"], 1)
        self.assertEqual(case["question_checks_assessed"], 0)
        self.assertEqual(case["question_checks_unassessed"], 4)
        self.assertEqual(case["question_checks_applicable"], 4)
        self.assertEqual(case["question_checks_evidence_excluded"], 4)
        self.assertEqual(case["targets"][0]["status"], "not_applicable")
        self.assertEqual(case["targets"][0]["original_evidence"], original)
        self.assertEqual(case["targets"][0]["original_evidence_status"], "supplied")
        self.assertFalse(case["targets"][0]["eligible_defect_check"])
        self.assertIsNone(case["priority"])
        self.assertEqual(case["question_answers_valid"], 3)
        self.assertEqual(case["high_signals"][0]["evidence_status"], "not_applicable")

    def test_applicability_exclusion_survives_missing_answer(self):
        data = fixture()
        data[2]["reports"][0]["judgments"].pop("target")
        data[2]["reports"][0]["not_applicable"] = ["target"]
        result = run_fixture(data)
        case = next(c for c in result["candidates"] if c["case_id"] == "a" and c["arm"] == "bank")
        self.assertEqual(case["question_checks_not_applicable"], 1)
        self.assertEqual(case["question_checks_unassessed"], 4)
        self.assertEqual(case["question_answers_valid"], 0)
        self.assertEqual(case["question_answers_expected"], 15)
        self.assertEqual(case["targets"][0]["status"], "not_applicable")

    def test_post_capture_interpretation_and_provisional_observability_are_disclosed(self):
        data = fixture()
        data[0]["questions"][0]["section"] = "observability"
        audit = {"interpretation_version": "2026-09-21.2", "post_capture": True,
                 "reason": "Apply section premises", "scope": "Tests and Views only",
                 "source_sha256": "a" * 64, "original_summary_sha256": "b" * 64,
                 "cases": {"a": {"style": "No changed views"}}}
        data[2]["presentation_interpretation"] = audit
        result = run_fixture(data)
        self.assertEqual(result["presentation_interpretation"], audit)
        self.assertEqual(result["scopes"]["train"]["arms"]["bank"]
                         ["question_checks_provisional_applicability"], 2)
        case = next(c for c in result["candidates"] if c["case_id"] == "a" and c["arm"] == "bank")
        self.assertEqual(case["targets"][0]["applicability_status"], "provisional")
        self.assertTrue(case["targets"][0]["eligible_defect_check"])
        rendered = metrics.render_markdown(result)
        self.assertIn("2026-09-21.2", rendered)
        self.assertIn("after capture", rendered)
        self.assertIn("Observability", rendered)
        self.assertIn("provisional", rendered)

    def test_good_direction_preserves_raw_high_without_false_alarm(self):
        data = fixture()
        data[0]["questions"][0]["direction"] = "yes_is_good"
        result = run_fixture(data)
        case = next(c for c in result["candidates"] if c["case_id"] == "a" and c["arm"] == "bank")
        self.assertAlmostEqual(case["priority"], .1)
        self.assertFalse(case["intended_mechanism_signal"])
        self.assertTrue(case["high_signals"][0]["raw_yes_high"])
        self.assertFalse(case["high_signals"][0]["directed_high"])

    def test_incidental_control_signal_is_never_confirmed_false_positive(self):
        data = fixture()
        control = next(r for r in data[2]["reports"] if r["case_id"] == "b" and r["arm"] == "bank")
        control["judgments"]["incidental"] = judgment(.99)
        result = run_fixture(data)
        receipt = result["scopes"]["train"]["arms"]["bank"]
        self.assertEqual(receipt["controls_with_any_eligible_alarm"], 1)
        self.assertEqual(receipt["controls_with_target_question_alarm"], 0)
        self.assertNotIn("false_positives", receipt)
        self.assertIn("unverified", metrics.render_markdown(result).lower())

    def test_top_k_boundary_ties_report_expected_count_and_bounds(self):
        rows = [{"case_id": "a", "planted_defect": True, "priority": .8},
                {"case_id": "b", "planted_defect": False, "priority": .8}]
        top = metrics.ranking_metrics(rows)["top_k"][0]
        self.assertEqual(top["k"], 1)
        self.assertEqual(top["expected_planted_defects"], .5)
        self.assertEqual(top["minimum_planted_defects"], 0)
        self.assertEqual(top["maximum_planted_defects"], 1)
        self.assertEqual(top["enrichment_over_scheduled_prevalence"], 1)

    def test_holdout_and_development_are_separate(self):
        data = fixture()
        extra = copy.deepcopy(data[1])
        extra_reports = copy.deepcopy(data[2]["reports"])
        for case in extra:
            case["id"] += "h"
            case["pair_id"] = "held"
            case["split"] = "holdout"
        for report in extra_reports:
            report["case_id"] += "h"
            report["split"] = "holdout"
        data[1].extend(extra)
        data[2]["reports"].extend(extra_reports)
        data[1][0]["split"] = data[1][1]["split"] = "development"
        result = run_fixture(data)
        self.assertEqual(result["scopes"]["train"]["pairs"], 1)
        self.assertEqual(result["scopes"]["holdout"]["pairs"], 1)
        self.assertEqual(result["scopes"]["all"]["pairs"], 2)

    def test_schema_legacy_mapping_uses_real_catalog_identifier(self):
        case = {"family": "schema"}
        self.assertEqual(metrics.target_ids(case), ["db_validation_without_constraint"])

    def test_schema_mapping_audit_preserves_source_phrase_and_nominal_alarm(self):
        data = fixture()
        source_phrase = "Does the change add a model validation (presence, uniqueness, foreign key) with no matching database constraint or index?"
        data[0]["questions"][0].update(id="db_validation_without_constraint", instructions=source_phrase)
        for case in data[1]:
            case["family"] = "schema"
            case["target_question_ids"] = ["db_validation_without_constraint"]
        for report in data[2]["reports"]:
            if report["arm"] == "bank":
                report["judgments"]["db_validation_without_constraint"] = report["judgments"].pop("target")
        original = copy.deepcopy(data)
        result = run_fixture(data)
        self.assertEqual(data, original)
        audit = result["pairs"][0]["target_mapping_audit"]
        self.assertEqual(audit["status"], "not_applicable_target")
        self.assertEqual(audit["questions"][0]["instructions"], source_phrase)
        self.assertIn("validation is unchanged", audit["reason"])
        arm = result["scopes"]["train"]["arms"]["bank"]
        self.assertEqual(arm["nominal_target_alarms_on_defect_candidates"], 1)
        self.assertEqual(arm["intended_mechanism_signals"], 1)
        self.assertEqual(arm["defects_with_any_eligible_alarm"], 1)
        self.assertEqual(arm["post_hoc_target_mapping"]["mapped_defect_candidates"], 0)
        self.assertEqual(result["pairs"][0]["arms"]["bank"]["defect_priority"], .9)
        rendered = metrics.render_markdown(result)
        self.assertIn("Nominal target alarms", rendered)
        self.assertIn("not a Jev miss", rendered)

    def test_default_scope_audit_identifies_both_invalid_targets_without_rewriting(self):
        bank = json.loads(Path(__file__).with_name("catalog.json").read_text())
        original = copy.deepcopy(bank)
        case = {"family": "default_scope", "target_question_ids": ["ar_default_scope", "disposition"]}
        audit = metrics.target_mapping_audit(case, bank)
        self.assertEqual(bank, original)
        self.assertEqual(audit["status"], "no_valid_mechanism_target")
        by_id = {q["question_id"]: q for q in audit["questions"]}
        self.assertEqual(by_id["ar_default_scope"]["instructions"],
                         "Does the change add or widen a `default_scope`?")
        self.assertEqual(by_id["ar_default_scope"]["status"], "not_applicable_target")
        self.assertEqual(by_id["disposition"]["status"], "required_evidence_missing")
        self.assertIn("siblings", by_id["disposition"]["reason"])
        self.assertTrue(audit["post_hoc"])

    def test_usage_and_latency_keep_missing_receipts_visible(self):
        data = fixture()
        data[3]["attempts"] = [
            {"id": "one", "case_id": "a", "arm": "bank", "status": "valid",
             "usage": {"input_tokens": 1000, "output_tokens": 20}, "elapsed_seconds": 2.5},
            {"id": "two", "case_id": "b", "arm": "bank", "status": "error"}]
        result = run_fixture(data)
        cost = result["scopes"]["train"]["arms"]["bank"]["operations"]
        self.assertEqual(cost["input_tokens_known"], 1000)
        self.assertEqual(cost["usage_unknown_attempts"], 1)
        self.assertEqual(cost["request_seconds_sum_known"], 2.5)
        self.assertEqual(cost["latency_unknown_attempts"], 1)
        self.assertAlmostEqual(cost["estimated_cost_usd_known_usage"], .000042)
        self.assertIsNone(cost["arm_wall_seconds"])

    def test_missing_responses_count_in_denominator_and_private_paths_are_dropped(self):
        data = fixture()
        result = run_fixture(data)
        arm = result["scopes"]["train"]["arms"]["bank"]
        self.assertEqual(arm["question_checks_intended"], 10)
        self.assertEqual(arm["question_answers_expected"], 30)
        self.assertEqual(arm["question_answers_valid"], 6)
        self.assertNotIn("/home/private", json.dumps(result))
        self.assertNotIn("/home/private", metrics.render_markdown(result))

    def test_cli_outputs_receipts_without_copying_private_coordinator_fields(self):
        catalog, cases, summary, capture = fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, value in [("catalog.json", catalog), ("coordinator-cases.json", cases),
                                ("summary.json", summary), ("capture.json", capture)]:
                (root / name).write_text(json.dumps(value))
            result = metrics.run(root)
            self.assertTrue((root / "metrics.json").exists())
            self.assertTrue((root / "metrics.md").exists())
            self.assertEqual(set(result["inputs"]),
                             {"catalog.json", "coordinator-cases.json", "summary.json", "capture.json"})
            self.assertNotIn(directory, (root / "metrics.md").read_text())

    def test_post_capture_run_binds_original_summary_and_audit(self):
        catalog, cases, summary, capture = fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = json.dumps(summary).encode()
            audit = {"interpretation_version": "2026-09-21.2", "post_capture": True,
                     "source_sha256": "a" * 64, "cases": {},
                     "original_summary_sha256": hashlib.sha256(original).hexdigest()}
            summary["presentation_interpretation"] = audit
            for name, value in [("catalog.json", catalog), ("coordinator-cases.json", cases),
                                ("summary.json", summary), ("capture.json", capture),
                                ("presentation-audit.json", audit)]:
                (root / name).write_text(json.dumps(value))
            (root / "summary-initial.json").write_bytes(original)
            result = metrics.run(root)
            self.assertEqual(result["inputs"]["summary-initial.json"]["sha256"],
                             audit["original_summary_sha256"])
            saved = (root / "metrics.json").read_bytes()
            (root / "summary-initial.json").write_bytes(original + b" ")
            with self.assertRaisesRegex(ValueError, "Original summary differs"):
                metrics.run(root)
            self.assertEqual((root / "metrics.json").read_bytes(), saved)


if __name__ == "__main__":
    unittest.main()
