#!/usr/bin/env python3
"""Bounded, source-bound documentation judgments. Importing never calls a provider."""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
TRANSPORT = HERE.parent / "rails_bank" / "runner.py"
spec = importlib.util.spec_from_file_location("docs_audit_transport", TRANSPORT)
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)
MODEL = "jev-1.13.0"
VERSION = "2026-09-21.1"


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def read(path):
    def unique(pairs):
        out = {}
        for key, value in pairs:
            if key in out:
                raise ValueError("duplicate_json_key")
            out[key] = value
        return out
    return json.loads(Path(path).read_bytes(), object_pairs_hook=unique,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError("nonfinite_json")))


def write(path, value):
    transport.write(Path(path), value)


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def safe_path(root, name):
    part = Path(name)
    if part.is_absolute() or ".." in part.parts or "\\" in name or ":" in name:
        raise ValueError("unsafe_path")
    path = root / part
    if any((root / Path(*part.parts[:i])).is_symlink() for i in range(1, len(part.parts) + 1)):
        raise ValueError("symlink_source")
    return path


def sections(raw):
    """Exact UTF-8 line spans between ATX headings outside fenced code.

    These are heading-content sections: a parent introduction ends before its
    first child heading. Ancestor headings are retained as context, not copied
    as though their children were supplied. Setext headings are ordinary text.
    """
    text = raw.decode("utf-8")
    lines = text.splitlines(keepends=True)
    starts = [(0, "Preamble", [])]
    stack, fence = [], None
    for i, line in enumerate(lines):
        mark = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line.rstrip("\r\n"))
        if fence:
            if mark and mark[1][0] == fence[0] and len(mark[1]) >= fence[1] and not mark[2].strip():
                fence = None
            continue
        if mark:
            fence = (mark[1][0], len(mark[1]))
            continue
        heading = re.match(r"^ {0,3}(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*(?:\r?\n)?$", line)
        if heading:
            level, title = len(heading[1]), heading[2]
            stack = [(n, s) for n, s in stack if n < level]
            starts.append((i, title, [s for _, s in stack]))
            stack.append((level, title))
    if fence:
        raise ValueError("unclosed_fence")
    result = []
    for n, (start, title, ancestors) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(lines)
        if start == end:
            continue
        body = "".join(lines[start:end])
        result.append({"heading": title, "ancestors": ancestors, "start_line": start + 1,
                       "end_line": end, "text": body, "sha256": sha(body.encode())})
    assert "".join(s["text"] for s in result).encode() == raw
    return result


def blocks(section):
    """Selectable paragraph/fence blocks; no content is discarded or shortened."""
    lines = section["text"].splitlines(keepends=True)
    result, start, fence = [], 0, None
    for i, line in enumerate(lines):
        mark = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line.rstrip("\r\n"))
        if fence:
            if mark and mark[1][0] == fence[0] and len(mark[1]) >= fence[1] and not mark[2].strip():
                fence = None
        elif mark:
            fence = (mark[1][0], len(mark[1]))
        if not fence and not line.strip():
            if any(x.strip() for x in lines[start:i]):
                result.append((start, i + 1))
            start = i + 1
    if any(x.strip() for x in lines[start:]):
        result.append((start, len(lines)))
    return [{"id": f"B{i:02}", "start_line": section["start_line"] + a,
             "end_line": section["start_line"] + b - 1,
             "text": "".join(lines[a:b])} for i, (a, b) in enumerate(result, 1)]


def questions(rubric, candidates):
    out = copy.deepcopy(rubric["questions"])
    choices = {"none": "No supplied block warrants this kind of revision or accuracy investigation."}
    choices.update({b["id"]: f"The complete document block with id {b['id']} in doc.blocks, lines {b['start_line']}–{b['end_line']}." for b in candidates})
    if len(choices) > 255:
        raise ValueError("too_many_blocks")
    for dimension in ("readability", "relevance", "accuracy"):
        out[dimension + "_target"]["criteria"] = choices
    return out


def source_span(root, item, source_hashes):
    path = safe_path(root, item["path"])
    raw = path.read_bytes()
    source_hashes[item["path"]] = sha(raw)
    lines = raw.decode("utf-8").splitlines(keepends=True)
    start, end = item.get("start", 1), item.get("end", len(lines))
    if not 1 <= start <= end <= len(lines):
        raise ValueError("source_range")
    text = "".join(lines[start - 1:end])
    return {"path": item["path"], "start_line": start, "end_line": end,
            "file_sha256": sha(raw), "span_sha256": sha(text.encode()), "text": text}


def prepare(args):
    root, source = Path(args.root), Path(args.source)
    if root.exists() and any(root.iterdir()):
        raise ValueError("output_not_empty")
    plan, rubric = read(args.plan), read(HERE / "rubric.json")
    revision = git(source, "rev-parse", "HEAD")
    if revision != plan["revision"] or git(source, "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("source_revision_or_dirty")
    schedule, coverage, source_hashes, requests = [], [], {}, []
    for page in plan["pages"]:
        raw = safe_path(source, page["path"]).read_bytes()
        source_hashes[page["path"]] = sha(raw)
        all_sections = sections(raw)
        selected = []
        for title in page["sections"]:
            matches = [s for s in all_sections if s["heading"] == title]
            if len(matches) != 1:
                raise ValueError("ambiguous_or_missing_heading: " + page["path"] + " / " + title)
            selected.append(matches[0])
        evidence = [source_span(source, item, source_hashes) for item in page["evidence"]]
        coverage.append({"path": page["path"], "sha256": sha(raw), "total_bytes": len(raw),
                         "sampled_bytes": sum(len(s["text"].encode()) for s in selected),
                         "sections": [{k: v for k, v in s.items() if k != "text"} | {"sampled": s in selected} for s in all_sections]})
        for section in selected:
            doc_blocks = blocks(section)
            state = {"repository_revision": revision, "audience": page["audience"],
                     "page_purpose": page["purpose"], "doc": {"path": page["path"],
                     **{k: v for k, v in section.items() if k != "text"}, "blocks": doc_blocks},
                     "implementation_evidence": evidence,
                     "evidence_limits": "Only the displayed source/spec spans were supplied. Omitted document sections and source are not checked. Source does not prove a command ran or an external current release exists. Missing evidence is unknown, not an error or a pass. Judge the pinned revision, not an imagined future final release."}
            request = {"model": MODEL, "state": state, "questions": questions(rubric, doc_blocks)}
            raw_request = transport.wire(request)
            longest = max(len(transport.wire(q)) for q in request["questions"].values())
            if len(transport.wire(state)) + longest > 30_000 or len(raw_request) > 60_000:
                raise ValueError("request_too_large: " + page["path"] + " / " + section["heading"])
            ident = f"D{len(schedule) + 1:03}"
            row = {"id": ident, "case_id": ident, "arm": "docs", "repeat": 0, "batch": 0,
                   "split": "train", "request": f"requests/{ident}.json", "sha256": sha(raw_request),
                   "state_sha256": sha(transport.wire(state)), "document": page["path"], "heading": section["heading"]}
            schedule.append(row)
            requests.append((row["request"], raw_request))
    if len(schedule) > 60:
        raise ValueError("request_limit")
    root.mkdir(parents=True, exist_ok=True)
    for name, raw in requests:
        p = root / name
        p.parent.mkdir(exist_ok=True)
        p.write_bytes(raw)
        p.chmod(0o600)
    write(root / "schedule.json", schedule)
    write(root / "catalog.json", rubric)  # Shared capture transport expects this identity file.
    write(root / "plan.json", plan)
    write(root / "coverage.json", coverage)
    write(root / "source-ledger.json", {"revision": revision, "files": source_hashes})
    (root / "protocol.md").write_bytes((HERE / "protocol.md").read_bytes())
    (root / "runner-snapshot.py.txt").write_bytes(Path(__file__).read_bytes())
    (root / "transport-snapshot.py.txt").write_bytes(TRANSPORT.read_bytes())
    write(root / "preflight.json", {"version": VERSION, "model": MODEL, "documents": len(coverage),
          "requests": len(schedule), "questions": sum(len(read(root / x["request"])["questions"]) for x in schedule),
          "max_request_bytes": max(len(raw) for _, raw in requests), "source_revision": revision,
          "sampled_bytes": sum(x["sampled_bytes"] for x in coverage), "selected_document_bytes": sum(x["total_bytes"] for x in coverage),
          "transport_sha256": sha(TRANSPORT.read_bytes()), "runner_sha256": sha(Path(__file__).read_bytes())})
    write(root / "input-freeze.json", {str(p.relative_to(root)): sha(p.read_bytes()) for p in sorted(root.rglob("*")) if p.is_file()})
    print(json.dumps(read(root / "preflight.json")))


def verify_source(root, source):
    transport.verify_inputs(root)
    ledger = read(root / "source-ledger.json")
    if git(source, "rev-parse", "HEAD") != ledger["revision"]:
        raise ValueError("source_revision_changed")
    for name, expected in ledger["files"].items():
        if sha(safe_path(source, name).read_bytes()) != expected:
            raise ValueError("source_changed: " + name)


def capture(args):
    root = Path(args.root)
    verify_source(root, Path(args.source))
    expected = read(root / "preflight.json")
    if sha(TRANSPORT.read_bytes()) != expected["transport_sha256"] or sha(Path(__file__).read_bytes()) != expected["runner_sha256"]:
        raise ValueError("capture_implementation_changed")
    transport.capture(args)


def summarize(args):
    root = Path(args.root)
    transport.verify_inputs(root)
    capture_data = read(root / "capture.json")
    attempts = {a["id"]: a for a in capture_data["attempts"]}
    if len(attempts) != len(capture_data["attempts"]):
        raise ValueError("duplicate_attempt")
    rows, usage, unknown = [], {"input_tokens": 0, "output_tokens": 0}, 0
    schedule = read(root / "schedule.json")
    if set(attempts) - {x["id"] for x in schedule}:
        raise ValueError("unexpected_attempt")
    for row in schedule:
        attempt = attempts.get(row["id"], {})
        result = {"id": row["id"], "document": row["document"], "heading": row["heading"],
                  "status": attempt.get("status", "not_attempted"), "answers": {}, "accuracy_assessment": "unassessed"}
        if attempt:
            if transport.valid_usage(attempt.get("usage")):
                for k in usage:
                    usage[k] += attempt["usage"][k]
            else:
                unknown += 1
        if attempt.get("response"):
            response_path = root / attempt["response"]
            if sha(response_path.read_bytes()) != attempt["response_sha256"]:
                raise ValueError("response_changed")
            if attempt.get("http_status") == 200:
                request, response = read(root / row["request"]), read(response_path)
                try:
                    validation = transport.validate_response(request, response)
                except ValueError:
                    validation = {"questions": {k: {"valid": False} for k in request["questions"]}}
                result["validation"] = validation
                result["answers"] = {qid: response["answers"][qid] for qid, v in validation["questions"].items() if v["valid"]}
                status = result["answers"].get("accuracy_status", {}).get("choice")
                result["accuracy_assessment"] = {"supported": "model_support_signal_only", "contradicted": "model_contradiction_lead", "missing_evidence": "unassessed_missing_evidence", "no_checkable_claim": "not_applicable"}.get(status, "unassessed")
        rows.append(result)
    output = {"version": VERSION, "source_revision": read(root / "source-ledger.json")["revision"],
              "requests_expected": len(schedule), "requests_attempted": len(attempts),
              "questions_expected": read(root / "preflight.json")["questions"],
              "questions_valid": sum(len(x["answers"]) for x in rows), "usage": usage,
              "unknown_usage_attempts": unknown, "estimated_known_input_usd": usage["input_tokens"] * .042 / 1_000_000,
              "rows": rows, "interpretation": "Model signals only. Scores are subjective dimensions, not probabilities of correctness. Every accuracy lead requires source/reproduction adjudication; a high confidence is never verification."}
    write(root / "summary.json", output)
    lines = ["# Sampled documentation signals", "", output["interpretation"], "", "| ID | Document / section | Readability 0–3 | Relevance 0–3 | Accuracy state | Selected accuracy block |", "| --- | --- | ---: | ---: | --- | --- |"]
    for row in rows:
        a = row["answers"]
        lines.append(f"| {row['id']} | {row['document']} / {row['heading'].replace('|', '/')} | {a.get('readability', {}).get('score', 'unknown')} | {a.get('relevance', {}).get('score', 'unknown')} | {row['accuracy_assessment']} | {a.get('accuracy_target', {}).get('choice', 'unknown')} |")
    (root / "summary.md").write_text("\n".join(lines) + "\n")
    print(json.dumps({k: v for k, v in output.items() if k != "rows"}))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare")
    prep.add_argument("--root", required=True)
    prep.add_argument("--source", required=True)
    prep.add_argument("--plan", default=str(HERE / "audit-plan.json"))
    cap = sub.add_parser("capture")
    cap.add_argument("--root", required=True)
    cap.add_argument("--source", required=True)
    cap.add_argument("--credential-command", nargs=argparse.REMAINDER)
    summary = sub.add_parser("summarize")
    summary.add_argument("--root", required=True)
    args = parser.parse_args()
    {"prepare": prepare, "capture": capture, "summarize": summarize}[args.command](args)


if __name__ == "__main__":
    main()
