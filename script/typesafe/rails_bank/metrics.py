#!/usr/bin/env python3
"""Offline descriptive metrics for the frozen Rails-bank comparison.

Only the planted mechanism has an executable oracle. High answers elsewhere,
including on control candidates, remain unverified signals rather than labeled
true/false positives. This module never contacts a provider or reads credentials.
"""

import argparse
from collections import Counter
import copy
import hashlib
import json
import math
from pathlib import Path
import re
import statistics


ARMS = ("baseline", "bank")
REPEATS = 3
HIGH = .8
INPUT_USD_PER_MILLION = .042
OUTPUT_USD_PER_MILLION = 0
BASELINE_IDS = ("correctness", "integrity", "security", "resources", "context_gap", "locate")
LEGACY_TARGETS = {
    "callback": ["ar_skips_validations"],
    "authorization": ["sec_missing_authorization"],
    "transaction": ["job_enqueued_inside_transaction"],
    "schema": ["db_validation_without_constraint"],
}


def number(value, low=0, high=None):
    return (type(value) in (int, float) and math.isfinite(value) and value >= low
            and (high is None or value <= high))


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", value):
        raise ValueError("Expected an opaque identifier, not a path or free-form source")
    return value


def split_name(value):
    if value in (None, "development", "train"):
        return "train"
    if value == "holdout":
        return value
    raise ValueError("Unknown evaluation split")


def target_ids(case):
    return list(case.get("target_question_ids", LEGACY_TARGETS.get(case["family"], [])))


def target_mapping_audit(case, catalog):
    """Annotate reviewed mapping errors; never change question eligibility/rank."""
    family = case["family"]
    expected = {"schema": ["db_validation_without_constraint"],
                "default_scope": ["ar_default_scope", "disposition"]}
    if family not in expected or set(target_ids(case)) != set(expected[family]):
        return None
    bank = {q["id"]: q for q in catalog["questions"]}
    if family == "schema":
        reason = ("The original schema pair changes only the index; the model validation is unchanged. "
                  "The nominal target asks whether the change adds a validation. Its absence is a target-mapping error, not a Jev miss.")
        details = [("db_validation_without_constraint", "not_applicable_target", reason)]
        status = "not_applicable_target"
    else:
        reason = ("The query changes visibility by using unscoped while the model's default_scope declaration is unchanged. "
                  "The scope question asks about adding or widening that declaration, and disposition requires missing siblings. "
                  "Neither nominal target provides a valid mechanism target for this pair; this is not a Jev miss.")
        details = [
            ("ar_default_scope", "not_applicable_target", "The query uses unscoped; the default_scope declaration is neither added nor widened."),
            ("disposition", "required_evidence_missing", "The required siblings context was not supplied; this Choice is also a next-step recommendation rather than a mechanism check."),
        ]
        status = "no_valid_mechanism_target"
    return {"audit_version": "2026-09-21.3-target-mapping", "post_hoc": True,
            "family": family, "status": status, "reason": reason,
            "excluded_from_mapping_audited_denominator": True,
            "questions": [{"question_id": qid, "instructions": bank[qid]["instructions"],
                           "status": state, "reason": explanation} for qid, state, explanation in details],
            "effect": "Annotation and secondary denominator only. Original questions, answers, eligibility, thresholds, nominal target alarms, candidate priorities, and rankings are unchanged."}


def baseline_metadata(qid):
    return {"id": qid, "type": "choice" if qid == "locate" else "noul",
            "kind": "defect" if qid in BASELINE_IDS[:4] else "fact",
            "direction": "unordered" if qid == "locate" else "yes_is_bad"}


def answer_receipt(meta, judgment):
    """Derive direction from frozen metadata, never from a stored risk number."""
    judgment = judgment or {}
    raw = judgment.get("raw", [])
    typ = meta["type"]
    if not isinstance(raw, list):
        raise ValueError("Invalid summarized answers")
    values = [answer.get(typ) for answer in raw]
    if typ == "noul" and not all(number(v, high=1) for v in values):
        raise ValueError("Invalid summarized Noul")
    if typ == "score" and not all(number(v, high=len(meta["criteria"]) - 1) for v in values):
        raise ValueError("Invalid summarized Score")
    if typ == "choice" and not all(isinstance(v, str) for v in values):
        raise ValueError("Invalid summarized Choice")
    valid = judgment.get("valid_repeats", len(raw))
    if type(valid) is not int or valid != len(raw) or not 0 <= valid <= REPEATS:
        raise ValueError("Invalid repeat count")
    complete = (valid == REPEATS and judgment.get("expected_repeats", REPEATS) == REPEATS
                and judgment.get("complete_repeats", False))
    evidence = judgment.get("evidence", {})
    status = evidence.get("status", "unknown")
    if status not in ("supplied", "not_supplied", "unknown", "not_applicable"):
        raise ValueError("Unknown evidence status")
    original_evidence = judgment.get("original_evidence", evidence)
    original_status = original_evidence.get("status", "unknown")
    missing = sorted(evidence.get("missing", {}))
    directed = ([1 - value if meta["direction"] == "yes_is_good" else value for value in values]
                if typ == "noul" else [])
    eligible_kind = typ == "noul" and meta["kind"] == "defect"
    eligible = eligible_kind and complete and status == "supplied"
    if status == "not_applicable":
        assessment = "not_applicable"
    elif not raw:
        assessment = "no_valid_answer"
    elif not complete:
        assessment = "incomplete_repeats"
    elif status != "supplied":
        assessment = "evidence_" + status
    elif not eligible_kind:
        assessment = "display_only_kind_or_type"
    else:
        assessment = "assessed"
    result = {"question_id": meta["id"], "type": typ, "kind": meta["kind"],
              "direction": meta["direction"], "values": values,
              "valid_repeats": valid, "expected_repeats": REPEATS,
              "complete_repeats": bool(complete), "evidence_status": status,
              "original_evidence": copy.deepcopy(original_evidence),
              "original_evidence_status": original_status,
              "evidence_reason": evidence.get("reason"),
              "applicability_status": ("not_applicable" if status == "not_applicable"
                                       else "provisional" if meta.get("section") == "observability"
                                       else "in_scope_or_unspecified"),
              "missing_requirements": missing, "status": assessment,
              "eligible_defect_check": bool(eligible),
              "directed_probability_median": statistics.median(directed) if directed else None}
    if typ == "noul":
        result.update(raw_yes_high=any(v >= HIGH for v in values),
                      directed_high=any(v >= HIGH for v in directed),
                      high_directed_repeats=sum(v >= HIGH for v in directed),
                      eligible_alarm=bool(eligible and statistics.median(directed) >= HIGH))
    elif typ == "score":
        result["normalized_display_values"] = [v / (len(meta["criteria"]) - 1) for v in values]
        result["confidence_values"] = [a.get("confidence") for a in raw]
    elif typ == "choice":
        result["confidence_values"] = [a.get("confidence") for a in raw]
    return result


def ranking_metrics(candidates):
    """Report descriptive, tie-aware top-K enrichment within one arm/split."""
    ranked = sorted((c for c in candidates if c["priority"] is not None),
                    key=lambda c: (-c["priority"], c["case_id"]))
    positive = sum(c["planted_defect"] for c in candidates)
    prevalence = positive / len(candidates) if candidates else None
    top = []
    for k in sorted({min(k, len(ranked)) for k in (1, 3, 6, 12, len(ranked))} - {0}):
        boundary = ranked[k - 1]["priority"]
        above = [c for c in ranked if c["priority"] > boundary]
        tied = [c for c in ranked if c["priority"] == boundary]
        places = k - len(above)
        certain = sum(c["planted_defect"] for c in above)
        tied_positive = sum(c["planted_defect"] for c in tied)
        expected = certain + places * tied_positive / len(tied)
        top.append({"k": k, "boundary_priority": boundary, "boundary_tie_size": len(tied),
                    "expected_planted_defects": expected,
                    "minimum_planted_defects": certain + max(0, places - (len(tied) - tied_positive)),
                    "maximum_planted_defects": certain + min(places, tied_positive),
                    "expected_planted_defect_fraction": expected / k,
                    "enrichment_over_scheduled_prevalence": expected / k / prevalence if prevalence else None})
    return {"scheduled_candidates": len(candidates), "rankable_candidates": len(ranked),
            "unrankable_candidates": len(candidates) - len(ranked),
            "scheduled_planted_defects": positive, "scheduled_prevalence": prevalence,
            "order": [{"case_id": c["case_id"], "priority": c["priority"],
                       "planted_defect": c["planted_defect"]} for c in ranked], "top_k": top}


def operations(attempts, schedule=None):
    known_usage = [a["usage"] for a in attempts if isinstance(a.get("usage"), dict)
                   and all(type(a["usage"].get(k)) is int and a["usage"][k] >= 0
                           for k in ("input_tokens", "output_tokens"))]
    timings = [a["elapsed_seconds"] for a in attempts if number(a.get("elapsed_seconds"))]
    inputs = sum(u["input_tokens"] for u in known_usage)
    outputs = sum(u["output_tokens"] for u in known_usage)
    errors, warnings = Counter(), Counter()
    for attempt in attempts:
        for q in attempt.get("validation", {}).get("questions", {}).values():
            errors.update(q.get("errors", []))
            warnings.update(q.get("warnings", []))
    return {"requests_expected": len(schedule) if schedule is not None else None,
            "requests_attempted": len(attempts),
            "request_statuses": dict(Counter(a["status"] for a in attempts)),
            "question_validation_errors": dict(errors), "question_validation_warnings": dict(warnings),
            "input_tokens_known": inputs, "output_tokens_known": outputs,
            "usage_known_attempts": len(known_usage), "usage_unknown_attempts": len(attempts) - len(known_usage),
            "estimated_cost_usd_known_usage": (inputs * INPUT_USD_PER_MILLION + outputs * OUTPUT_USD_PER_MILLION) / 1_000_000,
            "request_seconds_sum_known": sum(timings),
            "request_seconds_median": statistics.median(timings) if timings else None,
            "latency_unknown_attempts": len(attempts) - len(timings),
            "arm_wall_seconds": None}


def candidate_result(case, arm, report, catalog):
    targets = target_ids(case) if arm == "bank" else list(BASELINE_IDS[:4])
    metadata = catalog["questions"] if arm == "bank" else [baseline_metadata(q) for q in BASELINE_IDS]
    judgments = (report or {}).get("judgments", {})
    excluded = set((report or {}).get("not_applicable", []))
    expected_ids = {q["id"] for q in metadata}
    if set(judgments) - expected_ids or excluded - expected_ids or (arm == "bank" and set(targets) - expected_ids):
        raise ValueError("Unknown question ID in report or target mapping")
    receipts = []
    for q in metadata:
        judgment = judgments.get(q["id"])
        if q["id"] in excluded and not judgment:
            judgment = {"original_evidence": {"status": "unknown", "missing": {}},
                        "evidence": {"status": "not_applicable", "missing": {},
                                     "reason": "Excluded by the recorded section presentation interpretation; no valid answer was returned."}}
        receipts.append(answer_receipt(q, judgment))
    by_id = {r["question_id"]: r for r in receipts}
    eligible = [r for r in receipts if r["eligible_defect_check"]]
    alarms = [r for r in eligible if r["eligible_alarm"]]
    high_signals = []
    for r in receipts:
        if r["type"] == "noul" and (r["raw_yes_high"] or r["directed_high"]):
            role = ("designated_target" if r["question_id"] in targets else "incidental_unverified")
            if arm == "baseline":
                role = "broad_domain_signal" if r["question_id"] in targets else "context_signal"
            high_signals.append({**r, "role": role, "independently_confirmed_finding": False})
    target_receipts = [by_id[q] for q in targets]
    target_nouls = [r for r in target_receipts if r["type"] == "noul" and r["kind"] == "defect"]
    target_signal = any(r.get("eligible_alarm", False) for r in target_nouls) if arm == "bank" else None
    mapping_audit = target_mapping_audit(case, catalog) if arm == "bank" else None
    return {"case_id": case["id"], "pair_id": case["pair_id"], "family": case["family"],
            "split": case["split"], "arm": arm, "planted_defect": case["defect"],
            "priority": max((r["directed_probability_median"] for r in eligible), default=None),
            "eligible_alarm_question_ids": [r["question_id"] for r in alarms],
            "intended_mechanism_signal": target_signal if case["defect"] else None,
            "nominal_target_alarm": target_signal,
            "target_mapping_audit": mapping_audit,
            "target_question_alarm_on_control": target_signal if not case["defect"] else None,
            "has_defect_noul_target": bool(target_nouls) if arm == "bank" else None,
            "targets": target_receipts,
            "target_role": "nominal_target_checks" if arm == "bank" else "broad_domain_crosscheck",
            "high_signals": high_signals,
            "dimensions_and_choices": [r for r in receipts if r["type"] != "noul"],
            "question_checks_intended": len(receipts),
            "question_checks_applicable": sum(r["evidence_status"] != "not_applicable" for r in receipts),
            "question_checks_not_applicable": sum(r["evidence_status"] == "not_applicable" for r in receipts),
            "question_checks_assessed": sum(r["complete_repeats"] and r["evidence_status"] == "supplied" for r in receipts),
            "question_checks_unassessed": sum(r["evidence_status"] != "not_applicable" and
                                              (not r["complete_repeats"] or r["evidence_status"] != "supplied") for r in receipts),
            "question_checks_incomplete_repeats": sum(not r["complete_repeats"] for r in receipts),
            "question_checks_evidence_excluded": sum(r["evidence_status"] in ("not_supplied", "unknown") for r in receipts),
            "question_checks_original_evidence_excluded": sum(r["original_evidence_status"] in ("not_supplied", "unknown") for r in receipts),
            "question_checks_provisional_applicability": sum(r["applicability_status"] == "provisional" for r in receipts),
            "question_answers_expected": len(receipts) * REPEATS,
            "question_answers_valid": sum(r["valid_repeats"] for r in receipts)}


def arm_result(candidates, attempts, schedule):
    signals = [s for c in candidates for s in c["high_signals"]]
    arm = candidates[0]["arm"] if candidates else None
    defect = [c for c in candidates if c["planted_defect"]]
    control = [c for c in candidates if not c["planted_defect"]]
    mapped = [c for c in defect if not c["target_mapping_audit"]] if arm == "bank" else []
    result = {"defect_candidates": len(defect), "control_candidates": len(control),
              "defects_with_any_eligible_alarm": sum(bool(c["eligible_alarm_question_ids"]) for c in defect),
              "controls_with_any_eligible_alarm": sum(bool(c["eligible_alarm_question_ids"]) for c in control),
              "intended_mechanism_signals": sum(c["intended_mechanism_signal"] is True for c in defect) if arm == "bank" else None,
              "nominal_target_alarms_on_defect_candidates": sum(c["nominal_target_alarm"] is True for c in defect) if arm == "bank" else None,
              "post_hoc_target_mapping": {
                  "post_hoc": True,
                  "mapped_defect_candidates": len(mapped),
                  "nominal_target_alarms_on_mapped_defect_candidates": sum(c["nominal_target_alarm"] is True for c in mapped),
                  "excluded_defect_candidates": [c["case_id"] for c in defect if c["target_mapping_audit"]],
                  "excluded_families": sorted({c["family"] for c in defect if c["target_mapping_audit"]}),
                  "interpretation": "Secondary source-audit denominator; not an independent detection-accuracy estimate or a new ranking.",
              } if arm == "bank" else None,
              "controls_with_target_question_alarm": sum(c["target_question_alarm_on_control"] is True for c in control) if arm == "bank" else None,
              "defect_cases_without_defect_noul_target": sum(not c["has_defect_noul_target"] for c in defect) if arm == "bank" else None,
              "raw_high_signal_records": len(signals),
              "raw_high_signals_by_kind": dict(Counter(s["kind"] for s in signals)),
              "raw_high_signals_by_evidence": dict(Counter(s["evidence_status"] for s in signals)),
              "raw_high_signals_by_original_evidence": dict(Counter(s["original_evidence_status"] for s in signals)),
              "raw_high_signal_records_excluded_from_defect_checks": sum(not s["eligible_defect_check"] for s in signals),
              "ranking": ranking_metrics(candidates), "operations": operations(attempts, schedule)}
    for key in ("question_checks_intended", "question_checks_applicable", "question_checks_not_applicable",
                "question_checks_assessed", "question_checks_unassessed", "question_checks_incomplete_repeats",
                "question_checks_evidence_excluded", "question_checks_original_evidence_excluded",
                "question_checks_provisional_applicability", "question_answers_expected", "question_answers_valid"):
        result[key] = sum(c[key] for c in candidates)
    result["question_answers_invalid_or_missing"] = result["question_answers_expected"] - result["question_answers_valid"]
    return result


def pair_result(pair, candidates):
    result = {"pair_id": pair[0]["pair_id"], "family": pair[0]["family"],
              "split": pair[0]["split"], "arms": {}}
    for arm in ARMS:
        rows = [c for c in candidates if c["pair_id"] == result["pair_id"] and c["arm"] == arm]
        defect = next(c for c in rows if c["planted_defect"])
        control = next(c for c in rows if not c["planted_defect"])
        d, c = defect["priority"], control["priority"]
        ordering = "unrankable" if d is None or c is None else "defect_higher" if d > c else "control_higher" if c > d else "tie"
        result["arms"][arm] = {"defect_case_id": defect["case_id"], "control_case_id": control["case_id"],
                               "defect_priority": d, "control_priority": c, "priority_order": ordering,
                               "defect_target_answers": defect["targets"], "control_target_answers": control["targets"],
                               "intended_mechanism_signal": defect["intended_mechanism_signal"],
                               "nominal_target_alarm": defect["nominal_target_alarm"],
                               "target_question_alarm_on_control": control["target_question_alarm_on_control"]}
        if arm == "bank":
            result["target_mapping_audit"] = defect["target_mapping_audit"]
    return result


def build_metrics(summary, cases, capture, catalog, schedule=None):
    clean_cases = []
    for case in cases:
        if type(case.get("defect")) is not bool:
            raise ValueError("A Boolean planted-mechanism oracle label is required")
        clean_cases.append({"id": identifier(case["id"]), "family": identifier(case["family"]),
                            "pair_id": identifier(case.get("pair_id", case["family"])),
                            "split": split_name(case.get("split")), "defect": case["defect"],
                            "target_question_ids": [identifier(q) for q in target_ids(case)]})
    by_id = {c["id"]: c for c in clean_cases}
    if len(by_id) != len(clean_cases):
        raise ValueError("Duplicate candidate IDs")
    pairs = {}
    for case in clean_cases:
        pairs.setdefault(case["pair_id"], []).append(case)
    for pair in pairs.values():
        if (len(pair) != 2 or {c["defect"] for c in pair} != {True, False}
                or len({c["split"] for c in pair}) != 1 or len({c["family"] for c in pair}) != 1
                or pair[0]["target_question_ids"] != pair[1]["target_question_ids"]):
            raise ValueError("Pairs require matching targets/split and one defect/control each")
    reports = {}
    for report in summary["reports"]:
        key = (report["case_id"], report["arm"])
        if key in reports or key[0] not in by_id or key[1] not in ARMS:
            raise ValueError("Invalid or duplicate report identity")
        if split_name(report.get("split")) != by_id[key[0]]["split"]:
            raise ValueError("Report split differs from case")
        reports[key] = report
    for row in capture["attempts"] + (schedule or []):
        if row["case_id"] not in by_id or row["arm"] not in ARMS:
            raise ValueError("Unknown capture or schedule identity")
    candidates = [candidate_result(c, arm, reports.get((c["id"], arm)), catalog)
                  for c in clean_cases for arm in ARMS]
    pair_reports = [pair_result(pair, candidates) for _, pair in sorted(pairs.items())]
    scopes = {}
    for scope in ("train", "holdout", "all"):
        included = {c["id"] for c in clean_cases if scope == "all" or c["split"] == scope}
        scopes[scope] = {"pairs": sum(scope == "all" or p[0]["split"] == scope for p in pairs.values()), "arms": {}}
        for arm in ARMS:
            cs = [c for c in candidates if c["case_id"] in included and c["arm"] == arm]
            attempts = [a for a in capture["attempts"] if a["case_id"] in included and a["arm"] == arm]
            scheduled = [s for s in schedule if s["case_id"] in included and s["arm"] == arm] if schedule is not None else None
            scopes[scope]["arms"][arm] = arm_result(cs, attempts, scheduled)
            scopes[scope]["arms"][arm]["pair_priority_order"] = dict(Counter(
                p["arms"][arm]["priority_order"] for p in pair_reports if scope == "all" or p["split"] == scope))
    return {"schema_version": 1, "metrics_version": "rails-bank-descriptive-v3",
            "bank_version": catalog.get("bank_version"), "interpretation_version": catalog.get("interpretation_version"),
            "presentation_interpretation": copy.deepcopy(summary.get("presentation_interpretation")),
            "target_mapping_audit": {
                "audit_version": "2026-09-21.3-target-mapping", "post_hoc": True,
                "scope": "Source review of the original schema and default_scope family/target mappings in this trial. No question, answer, threshold, eligibility, ranking, or holdout selection changes.",
                "pairs": {p["pair_id"]: p["target_mapping_audit"] for p in pair_reports if p["target_mapping_audit"]},
                "legacy_field_semantics": {
                    "intended_mechanism_signal": "Historical field retained numerically; means nominal target alarm, not attributed mechanism detection.",
                    "intended_mechanism_signals": "Historical count retained numerically; means nominal target alarms on defect candidates, not detection accuracy.",
                },
            },
            "model": capture.get("model"),
            "policy": {"high_threshold": HIGH, "expected_repeats": REPEATS,
                       "priority": "Maximum median directed Noul among complete, supplied, defect-kind checks; navigation ordering only, never calibrated change risk.",
                       "high_signals": "Retain a Noul if any valid repeat is >=0.8 raw yes or directed probability, even when evidence/kind/repeats exclude it from defect checks.",
                       "target_signal": "A nominal target alarm means an eligible designated defect Noul has median >=0.8. This is not a detection count: target mapping can be wrong, and the fixture oracle does not establish provider attribution. Historical intended_mechanism fields are preserved numeric aliases only.",
                       "baseline_signal": "Broad domain answers cannot identify which mechanism caused an alarm; no intended-mechanism detection count is claimed.",
                       "control_signal": "A control excludes the planted mechanism only. Its other alarms are not confirmed false positives.",
                       "applicability": "not_applicable is separate from supplied, not_supplied, and unknown. It never counts as assessed, unassessed, missing evidence, or an eligible defect check. Original ledger statuses are retained. Applicable means not deterministically excluded, not proof of universal semantic applicability.",
                       "answer_denominators": "All originally requested questions and repeats remain in provider-validity and cost denominators, including questions later marked not_applicable.",
                       "observability_applicability": "Source-bank Observability section scope remains unresolved; its signals and any rankings they influence are provisional. They remain included under the fixed presentation policy.",
                       "ranking": "Within-arm top-K only; boundary ties use uniform expected label counts and min/max bounds. Reference prevalence includes every scheduled candidate, including unrankable ones.",
                       "limits": "Small curated paired fixtures, reused development cases, correlated questions, and unequal question counts do not establish general review quality, AUC success, or downstream effort savings.",
                       "input_usd_per_million_assumed": INPUT_USD_PER_MILLION,
                       "output_usd_per_million_assumed": OUTPUT_USD_PER_MILLION,
                       "cost": "Estimate from known usage at the frozen assumed rates, not an invoice or current pricing claim. Unknown usage remains separate.",
                       "time": "Request elapsed seconds are summed/median; concurrent request sums are not arm wall-clock time. No downstream reviewer time is measured."},
            "scopes": scopes, "pairs": pair_reports, "candidates": candidates}


def format_values(receipt):
    values = ", ".join(f"{x:.2f}" if number(x) else str(x) for x in receipt["values"]) or "missing"
    return (f'`{receipt["question_id"]}` [{values}] ({receipt["kind"]}; '
            f'{receipt["evidence_status"]}; {receipt["valid_repeats"]}/3)')


def render_markdown(result):
    lines = ["# Rails bank comparison receipts", "",
             "These are descriptive results from curated defect/control fixtures. The oracle establishes only each planted mechanism. Incidental signals are unverified, and control alarms are not automatically false positives.", "",
             f'Bank `{result["bank_version"]}`; metadata `{result["interpretation_version"]}`. High-signal threshold: 0.8; three expected repeats.', "",
             "Priorities use the maximum median of eligible defect Nouls. Scores are display dimensions; Choices and conventions do not become defect probabilities. Compare rankings within each arm; the larger bank has more opportunities to produce an alarm."]
    audit = result.get("presentation_interpretation")
    if audit:
        timing = "after capture" if audit.get("post_capture") else "before capture"
        lines += ["", f'Presentation interpretation `{audit["interpretation_version"]}` was applied {timing}. The initial summary and reports remain preserved; the question bank and numerical thresholds are unchanged. The metrics receipt includes the presentation audit and original-summary digest.', "",
                  "Not-applicable checks are counted separately from assessed and missing/unknown checks. Provider-answer and usage denominators still include every question that was actually requested."]
    lines += ["", result["policy"]["observability_applicability"]]
    mapping_audit = result["target_mapping_audit"]
    if mapping_audit["pairs"]:
        lines += ["", "## Target mapping audit (post hoc)", "",
                  f'Source audit `{mapping_audit["audit_version"]}` identifies two nominal-target mapping problems. The original nominal target-alarm count is preserved; it is not detection accuracy. Candidate alarms, priorities, rankings, questions, answers, thresholds, and holdout selection are unchanged.', ""]
        for pair_id, item in mapping_audit["pairs"].items():
            lines.append(f'- `{pair_id}` / {item["family"]}: {item["reason"]}')
            for q in item["questions"]:
                lines.append(f'  Original `{q["question_id"]}`: {q["instructions"]} Mapping status: {q["status"]}.')
    for scope in ("train", "holdout", "all"):
        s = result["scopes"][scope]
        lines += ["", f"## {scope.capitalize()} — {s['pairs']} pairs", "",
                  "| Arm | Defect candidates with any alarm | Controls with any alarm | Nominal target alarms | Not applicable | Unassessed / applicable checks | Valid answers / expected |",
                  "| --- | --- | --- | --- | --- | --- | --- |"]
        for arm in ARMS:
            a = s["arms"][arm]
            target = f'{a["nominal_target_alarms_on_defect_candidates"]}/{a["defect_candidates"]}' if a["nominal_target_alarms_on_defect_candidates"] is not None else "Not attributable"
            lines.append(f'| {arm} | {a["defects_with_any_eligible_alarm"]}/{a["defect_candidates"]} | {a["controls_with_any_eligible_alarm"]}/{a["control_candidates"]} | {target} | {a["question_checks_not_applicable"]}/{a["question_checks_intended"]} | {a["question_checks_unassessed"]}/{a["question_checks_applicable"]} | {a["question_answers_valid"]}/{a["question_answers_expected"]} |')
        mapped = s["arms"]["bank"]["post_hoc_target_mapping"]
        if mapped:
            lines += ["", f'Post hoc mapping-audited subset: {mapped["nominal_target_alarms_on_mapped_defect_candidates"]}/{mapped["mapped_defect_candidates"]} nominal target alarms; {len(mapped["excluded_defect_candidates"])} pairs excluded for source-mapping errors. This secondary denominator is not independent detection validation.']
        lines += ["", "The nominal-target count preserves the original designated check alarms, not attributed detections or a model explanation. A missing, incomplete, or evidence-excluded check never counts as passed. Control counts above are alarm counts only.", "",
                  "| Arm | Requests attempted / expected | Input / output tokens known | Usage gaps | Estimated USD known | Sum request seconds | Median request seconds |",
                  "| --- | --- | --- | --- | --- | --- | --- |"]
        for arm in ARMS:
            o = s["arms"][arm]["operations"]
            expected = o["requests_expected"] if o["requests_expected"] is not None else "unknown"
            median = f'{o["request_seconds_median"]:.2f}' if o["request_seconds_median"] is not None else "unknown"
            lines.append(f'| {arm} | {o["requests_attempted"]}/{expected} | {o["input_tokens_known"]} / {o["output_tokens_known"]} | {o["usage_unknown_attempts"]} | ${o["estimated_cost_usd_known_usage"]:.6f} | {o["request_seconds_sum_known"]:.2f} | {median} |')
        lines += ["", "Timing sums include concurrent requests and are not wall-clock time. Costs use the frozen $0.042/M input and $0/M output assumption; missing usage is excluded visibly.", "",
                  "| Arm | Top K | Expected planted defects [min–max] | Enrichment over scheduled prevalence | Boundary tie size |",
                  "| --- | --- | --- | --- | --- |"]
        for arm in ARMS:
            for top in s["arms"][arm]["ranking"]["top_k"]:
                enrichment = top["enrichment_over_scheduled_prevalence"]
                rendered = f"{enrichment:.2f}×" if enrichment is not None else "undefined"
                lines.append(f'| {arm} | {top["k"]} | {top["expected_planted_defects"]:.2f} [{top["minimum_planted_defects"]}–{top["maximum_planted_defects"]}] | {rendered} | {top["boundary_tie_size"]} |')
    lines += ["", "## Pair receipts", "", "Each bracket preserves every valid repeat. Scores and Choices are shown in their original units; they do not enter the defect priority."]
    for pair in result["pairs"]:
        lines += ["", f'### {pair["pair_id"]} — {pair["family"]} ({pair["split"]})', ""]
        if pair["target_mapping_audit"]:
            lines += ["Target mapping audit (post hoc): " + pair["target_mapping_audit"]["reason"], ""]
        for arm in ARMS:
            p = pair["arms"][arm]
            lines += [f'- **{arm}**: defect `{p["defect_case_id"]}` priority {p["defect_priority"]}; control `{p["control_case_id"]}` priority {p["control_priority"]}; {p["priority_order"]}.',
                      "  Defect checks: " + "; ".join(format_values(r) for r in p["defect_target_answers"]),
                      "  Control checks: " + "; ".join(format_values(r) for r in p["control_target_answers"])]
    lines += ["", "## Every high Noul signal, including excluded answers", "",
              "A row appears when any valid repeat has raw yes ≥0.8 or direction-adjusted probability ≥0.8. Eligibility additionally requires all three repeats, supplied evidence, and defect kind. A high raw yes on a yes-is-good check is not a defect alarm. No incidental row has been independently confirmed by this module."]
    for candidate in result["candidates"]:
        signals = candidate["high_signals"]
        if not signals:
            continue
        label = "planted defect" if candidate["planted_defect"] else "planted-mechanism control"
        lines += ["", f'### {candidate["case_id"]} / {candidate["arm"]} — {label}, {candidate["split"]}', "",
                  "| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |",
                  "| --- | --- | --- | --- | --- | --- | --- | --- |"]
        for r in signals:
            gaps = ", ".join(r["missing_requirements"])
            evidence = r["evidence_status"] + (f" ({gaps})" if gaps else "")
            if r["evidence_status"] != r["original_evidence_status"]:
                evidence += f'; original {r["original_evidence_status"]}'
            if r["applicability_status"] == "provisional":
                evidence += "; provisional applicability"
            values = ", ".join(f"{x:.2f}" for x in r["values"])
            lines.append(f'| `{r["question_id"]}` | {r["role"]} | {r["kind"]} / {r["direction"]} | {values} | {evidence} | {r["valid_repeats"]}/3 | {r["eligible_defect_check"]} | {r["directed_probability_median"]:.2f} |')
    lines += ["", "## Limits", "", result["policy"]["limits"], "",
              "The JSON receipt includes every displayed signal, target answer, Score/Choice dimension, request status, validation error count, missing-usage count, and tie-aware ranking. Source bodies, local application paths, credentials, and coordinator-only metadata are not copied here.", ""]
    return "\n".join(lines)


def run(root):
    root = Path(root)
    names = ("summary.json", "coordinator-cases.json", "capture.json", "catalog.json")
    raw = {name: (root / name).read_bytes() for name in names}
    data = {name: json.loads(value) for name, value in raw.items()}
    schedule = None
    if (root / "schedule.json").exists():
        raw["schedule.json"] = (root / "schedule.json").read_bytes()
        schedule = json.loads(raw["schedule.json"])
    result = build_metrics(data["summary.json"], data["coordinator-cases.json"], data["capture.json"], data["catalog.json"], schedule)
    audit = result.get("presentation_interpretation")
    if audit:
        original = (root / "summary-initial.json").read_bytes()
        if hashlib.sha256(original).hexdigest() != audit["original_summary_sha256"]:
            raise ValueError("Original summary differs from presentation audit")
        raw["summary-initial.json"] = original
        if (root / "presentation-audit.json").exists():
            raw["presentation-audit.json"] = (root / "presentation-audit.json").read_bytes()
            if json.loads(raw["presentation-audit.json"]) != audit:
                raise ValueError("Presentation audit differs from summary")
    result["inputs"] = {name: {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)} for name, value in raw.items()}
    outputs = {"metrics.json": json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False) + "\n",
               "metrics.md": render_markdown(result)}
    for name, content in outputs.items():
        temporary = root / (name + ".new")
        temporary.write_text(content, encoding="utf-8")
        temporary.chmod(0o600)
        temporary.replace(root / name)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    args = parser.parse_args()
    result = run(args.root)
    print(json.dumps({"metrics_version": result["metrics_version"],
                      "pairs": result["scopes"]["all"]["pairs"],
                      "receipts": ["metrics.json", "metrics.md"]}))


if __name__ == "__main__":
    main()
