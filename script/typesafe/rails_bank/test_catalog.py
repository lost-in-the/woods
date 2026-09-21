"""Offline provenance and contract checks for the imported Rails question bank."""

import collections
import hashlib
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parent
SOURCE_SHA256 = "41f293131e2d088e9efd53dd635cbd1e22b6bf8f7210fb5d38cef05b213d5c9b"
ROW = re.compile(r"^\| `([^`]+)` \| (Noul|Score|Choice) \| (.*) \|$")
SECTION_COUNTS = {
    "dhh": 11, "views": 12, "metz": 13, "tests": 25,
    "performance": 11, "database": 9, "batsov": 22, "avdi": 11,
    "vm": 9, "security": 16, "jobs": 10, "observability": 10,
    "codebase": 8, "rollout": 11, "blast": 8, "hygiene": 18,
}
HEADLINES = {
    "dhh": "dhh_conformance", "views": "view_logic_placement",
    "metz": "metz_blast_radius", "tests": "test_coverage_of_change",
    "performance": "perf_impact", "database": "db_migration_risk",
    "batsov": "ar_persistence_risk", "avdi": "avdi_return_contract",
    "vm": "vm_memory_impact", "security": "sec_worst_case_impact",
    "jobs": "job_failure_impact", "observability": "obs_debuggability",
    "codebase": "repo_fit", "rollout": "rollout_behavior_change_scope",
    "blast": "blast_data_reach", "hygiene": None,
}


class CatalogTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads((ROOT / "catalog.json").read_text())
        cls.snapshot = (ROOT / "source-question-bank.md").read_bytes()
        cls.lines = cls.snapshot.decode("utf-8").splitlines()
        cls.questions = cls.catalog["questions"]
        cls.by_id = {q["id"]: q for q in cls.questions}
        cls.sections = {s["id"]: s for s in cls.catalog["sections"]}

    def test_source_snapshot_is_byte_identical_to_attachment(self):
        self.assertEqual(hashlib.sha256(self.snapshot).hexdigest(), SOURCE_SHA256)
        self.assertEqual(self.catalog["source"]["sha256"], SOURCE_SHA256)
        self.assertEqual(self.catalog["source"]["path"], "source-question-bank.md")

    def test_counts_identity_and_order_match_every_original_row(self):
        source_rows = [ROW.match(line) for line in self.lines if ROW.match(line)]
        self.assertEqual(len(self.questions), 204)
        self.assertEqual(len(self.by_id), 204)
        self.assertEqual([q["id"] for q in self.questions], [m[1] for m in source_rows])
        self.assertEqual(collections.Counter(q["type"] for q in self.questions),
                         {"noul": 185, "score": 16, "choice": 3})
        self.assertEqual(collections.Counter(q["section"] for q in self.questions),
                         SECTION_COUNTS)
        self.assertEqual(len(self.sections), 16)

    def test_every_question_reconstructs_its_original_source_cell(self):
        for q in self.questions:
            with self.subTest(question=q["id"]):
                source = q["source"]
                row = self.lines[source["line"] - 1]
                match = ROW.fullmatch(row)
                self.assertEqual(source["row"], row)
                self.assertEqual((q["id"], q["type"]), (match[1], match[2].lower()))
                self.assertEqual(source["question_cell"], match[3])
                body = q["instructions"]
                if q["type"] == "score":
                    self.assertEqual(len(q["criteria"]), 4)
                    body += " — " + " · ".join(
                        f"{i} {text}" for i, text in enumerate(q["criteria"]))
                elif q["type"] == "choice":
                    body += " — " + " · ".join(
                        f"`{key}`" + (f" {text}" if text is not None else "")
                        for key, text in q["criteria"].items())
                else:
                    self.assertNotIn("criteria", q)
                self.assertEqual(source["context_prefix"] + body, source["question_cell"])

    def test_direction_exceptions_are_not_inferred_from_question_names(self):
        for q in self.questions:
            expected = {"noul": "yes_is_bad", "score": "higher_is_worse",
                        "choice": "unordered"}[q["type"]]
            expected = {"test_regression_for_fix": "yes_is_good",
                        "test_coverage_of_change": "higher_is_better"}.get(q["id"], expected)
            self.assertEqual(q["direction"], expected, q["id"])

    def test_purpose_headlines_take_precedence_over_old_prose(self):
        self.assertEqual({k: v["headline_score"] for k, v in self.sections.items()}, HEADLINES)
        for section, identifier in HEADLINES.items():
            if identifier:
                self.assertEqual(self.by_id[identifier]["type"], "score")
                self.assertEqual(self.by_id[identifier]["headline_role"], "primary")
                self.assertEqual(self.by_id[identifier]["section"], section)
        self.assertEqual(self.sections["rollout"]["secondary_headline_scores"],
                         ["rollout_user_visibility"])
        self.assertEqual(self.by_id["rollout_user_visibility"]["headline_role"],
                         "secondary_unweighted")
        self.assertFalse(any(q["headline_role"] for q in self.questions
                             if q["section"] == "hygiene"))

    def test_context_markers_and_section_requirements_are_machine_usable(self):
        registry = self.catalog["context_requirements"]
        self.assertEqual(sum(bool(q["source"]["context_note"]) for q in self.questions), 34)
        for q in self.questions:
            with self.subTest(question=q["id"]):
                requirements = q["context_requirements"]
                self.assertEqual(len(requirements), len(set(requirements)))
                self.assertTrue({"diff", "touched_source"}.issubset(requirements))
                self.assertTrue(set(requirements).issubset(registry))
                self.assertTrue(set(q["explicit_context_requirements"]).issubset(requirements))
                self.assertEqual(bool(q["explicit_context_requirements"]),
                                 bool(q["source"]["context_note"]))
                self.assertTrue(set(self.sections[q["section"]]["context_requirements"])
                                .issubset(requirements))
        self.assertEqual(self.sections["blast"]["context_requirements"],
                         ["callers", "reference_search"])
        self.assertEqual(self.sections["codebase"]["context_requirements"], ["siblings"])
        self.assertEqual(self.sections["hygiene"]["context_requirements"], ["change_intent"])
        self.assertEqual(registry["change_intent"]["any_of"],
                         ["pr_description", "commit_messages"])
        self.assertEqual(self.by_id["job_enqueued_inside_transaction"]
                         ["explicit_context_requirements"],
                         ["rails_version", "queue_adapter", "enqueue_after_transaction_commit"])
        self.assertEqual(self.by_id["test_regression_for_fix"]
                         ["explicit_context_requirements"], ["change_kind_fix"])
        self.assertFalse(registry["change_kind_fix"]["allow_same_batch_answer"])

    def test_kind_interpretations_have_an_audited_basis(self):
        interpretations = {item["id"] for item in self.catalog["interpretations"]}
        notes = (ROOT / "bank-corrections.md").read_text()
        for item in self.catalog["interpretations"]:
            for line in item["source_lines"]:
                self.assertTrue(self.lines[line - 1].strip(), item["id"])
        for q in self.questions:
            with self.subTest(question=q["id"]):
                self.assertIn(q["kind"], {"fact", "defect", "convention"})
                self.assertIn(q["kind_basis"]["interpretation"], interpretations)
                self.assertIn(q["kind_basis"]["interpretation"], notes)
                self.assertTrue(q["kind_basis"]["reason"])
        self.assertEqual(self.by_id["change_kind"]["kind"], "fact")
        self.assertEqual(self.by_id["primary_concern"]["kind"], "fact")
        self.assertEqual(self.by_id["test_private_method"]["kind"], "fact")
        self.assertEqual(self.by_id["repo_fit"]["kind"], "convention")
        self.assertEqual(self.by_id["view_broadcast_unscoped"]["kind"], "defect")
        self.assertEqual(self.by_id["ar_default_scope"]["kind"], "convention")

    def test_section_provenance_points_to_the_original_heading_and_prose(self):
        for section in self.sections.values():
            source = section["source"]
            self.assertEqual(self.lines[source["heading_line"] - 1],
                             "## " + section["title"])
            self.assertEqual(self.lines[source["description_line"] - 1],
                             source["description"])

    def test_version_and_corrections_do_not_claim_reworded_questions(self):
        self.assertEqual(self.catalog["schema_version"], 1)
        self.assertEqual(self.catalog["bank_version"], "2026-09-19.1")
        self.assertEqual(self.catalog["import_mode"], "as_written")
        self.assertEqual(self.catalog["corrections"], [])
        self.assertNotIn("edited_instructions", self.questions[0])
        self.assertTrue(all("edited_instructions" not in q for q in self.questions))


if __name__ == "__main__":
    unittest.main()
