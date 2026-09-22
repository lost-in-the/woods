"""Offline regressions for preserved presentation and bounded evidence rereads."""

import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent


def module(name):
    spec = importlib.util.spec_from_file_location("rails_bank_audit_" + name, HERE / (name + ".py"))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


runner = module("runner")
presentation = module("presentation")
reviewers = module("reviewers")


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


class PresentationTest(unittest.TestCase):
    def test_summarize_cannot_replace_a_versioned_presentation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write(root / "presentation-audit.json", {"interpretation_version": "2026-09-21.2"})
            write(root / "summary.json", {"corrected": True})
            (root / "reports").mkdir()
            (root / "reports/a.md").write_text("Preserve this corrected report.\n")
            before = {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}
            with patch.object(runner, "verify_inputs", side_effect=AssertionError("Guard must run first")):
                with self.assertRaisesRegex(ValueError, "refuse_overwriting_versioned_presentation"):
                    runner.summarize(argparse.Namespace(root=str(root)))
            self.assertEqual({p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}, before)

    def test_applicability_preserves_raw_answers_originals_and_general_test_questions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            catalog = json.loads((HERE / "catalog.json").read_text())
            wanted = {"test_cannot_fail", "view_broadcast_unscoped", "test_coverage_of_change",
                      "test_regression_for_fix", "obs_cause_lost"}
            catalog["questions"] = [q for q in catalog["questions"] if q["id"] in wanted]
            judgments = {q["id"]: {"type": q["type"], "kind": q["kind"], "risk": .9 if q["type"] == "noul" else None,
                                   "raw": [{q["type"]: .9}], "complete_repeats": True,
                                   "evidence": {"status": "supplied", "missing": {}}} for q in catalog["questions"]}
            report = {"case_id": "a", "arm": "bank", "judgments": judgments,
                      "shortlist": ["test_cannot_fail", "view_broadcast_unscoped", "obs_cause_lost"],
                      "likely": ["test_cannot_fail"], "unassessed": ["test_regression_for_fix"], "priority": .9}
            write(root / "summary.json", {"reports": [report]})
            write(root / "catalog.json", catalog)
            write(root / "packets/a.json", {"changed": ["app/services/example.rb"]})
            (root / "reports").mkdir()
            text = "- `test_cannot_fail`: original check\n- `obs_cause_lost`: preserved check\n"
            (root / "reports/a.md").write_text(text)
            original = (root / "summary.json").read_bytes()
            with contextlib.redirect_stdout(io.StringIO()):
                presentation.apply(root)
            corrected = json.loads((root / "summary.json").read_text())["reports"][0]
            self.assertEqual((root / "summary-initial.json").read_bytes(), original)
            self.assertEqual((root / "reports-initial/a.md").read_text(), text)
            self.assertEqual(set(corrected["not_applicable"]), {"test_cannot_fail", "view_broadcast_unscoped"})
            for qid, previous in judgments.items():
                self.assertEqual(corrected["judgments"][qid]["raw"], previous["raw"])
            self.assertEqual(corrected["judgments"]["test_cannot_fail"]["original_evidence"], judgments["test_cannot_fail"]["evidence"])
            self.assertEqual(corrected["shortlist"], ["obs_cause_lost"])
            self.assertIn("test_regression_for_fix", corrected["unassessed"])
            self.assertIn("provisional", (root / "reports/a.md").read_text())
            before = {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}
            with self.assertRaisesRegex(ValueError, "already applied"):
                presentation.apply(root)
            self.assertEqual({p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}, before)

    def test_delivery_helper_allows_rereads_but_caps_distinct_candidates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cases = [{"id": f"{i:08x}", "path": "app/services/example.rb", "brief": "Inspect captured source", "diff": "example"} for i in range(9)]
            write(root / "coordinator-cases.json", cases)
            write(root / "catalog.json", {"questions": []})
            write(root / "summary.json", {"reports": [
                {"case_id": c["id"], "arm": arm, "priority": None, "shortlist": [], "judgments": {}, "unassessed": []}
                for c in cases for arm in ("baseline", "bank")]})
            (root / "reports").mkdir()
            for c in cases:
                write(root / "packets" / (c["id"] + ".json"), {"source": "captured evidence"})
                (root / "reports" / (c["id"] + ".md")).write_text("Advisory report\n")
            with contextlib.redirect_stdout(io.StringIO()):
                reviewers.prepare(root, delivery_audit=True)
            directory = root / "reviewers-delivery/bank-0"
            helper = directory / "inspect.py"
            for case in [cases[0], cases[0]] + cases[1:8]:
                result = subprocess.run([sys.executable, str(helper), case["id"]], capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("captured evidence", result.stdout)
                self.assertIn("Advisory report", result.stdout)
            denied = subprocess.run([sys.executable, str(helper), cases[8]["id"]], capture_output=True, text=True, check=False)
            self.assertNotEqual(denied.returncode, 0)
            self.assertIn("Eight distinct candidates exhausted", denied.stderr)
            inspections = [json.loads(line) for line in (directory / "inspections.jsonl").read_text().splitlines()]
            self.assertEqual(len(inspections), 9)
            self.assertEqual(len({row["id"] for row in inspections}), 8)
            # Captured stdout is verified here; actual model-visible tool display
            # and attention cannot be established by this helper regression.


if __name__ == "__main__":
    unittest.main()
