#!/usr/bin/env python3
"""Prepare/run bounded, independent reviewer comparisons from frozen captures."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import signal
import subprocess
import threading
import time


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


def prepare(root, delivery_audit=False):
    folder = 'reviewers-delivery' if delivery_audit else 'reviewers'
    cases = read(root / 'coordinator-cases.json')
    summary = read(root / 'summary.json')
    bank = {q['id']: q for q in read(root / 'catalog.json')['questions']}
    reports = {(r['case_id'], r['arm']): r for r in summary['reports']}
    schema = {'type': 'object', 'properties': {
        'findings': {'type': 'array', 'items': {'type': 'object', 'properties': {
            'id': {'type': 'string'}, 'mechanism': {'type': 'string'},
            'evidence': {'type': 'string'}, 'kind': {'type': 'string', 'enum': ['defect', 'convention']}},
            'required': ['id', 'mechanism', 'evidence', 'kind'], 'additionalProperties': False}},
        'review_order': {'type': 'array', 'items': {'type': 'string'}},
        'false_leads': {'type': 'array', 'items': {'type': 'string'}},
        'unassessed': {'type': 'array', 'items': {'type': 'string'}},
        'limitations': {'type': 'string'}},
        'required': ['findings', 'review_order', 'false_leads', 'unassessed', 'limitations'], 'additionalProperties': False}
    write(root / folder / 'schema.json', schema)
    jobs = []
    for repeat in (0, 1):
        ordered = list(cases)
        random.Random(20260921 + repeat).shuffle(ordered)
        for arm in ('ordinary', 'baseline', 'bank'):
            name = f'{arm}-{repeat}'
            directory = root / folder / name
            directory.mkdir(parents=True, exist_ok=True)
            if (directory / 'events.jsonl').exists():
                raise ValueError('Refusing to overwrite reviewer run')
            inventory = [{'id': c['id'], 'path': c['path'], 'intent': c['brief'], 'diff': c['diff']} for c in ordered]
            write(directory / 'changes.json', inventory)
            (directory / 'evidence').mkdir(exist_ok=True)
            for c in cases:
                shutil.copy2(root / 'packets' / f'{c["id"]}.json', directory / 'evidence' / f'{c["id"]}.json')
            if arm != 'ordinary':
                listing = []
                for c in ordered:
                    report = reports[(c['id'], arm)]
                    listing.append({'id': c['id'], 'path': c['path'], 'intent': c['brief'],
                                    'priority': report['priority'],
                                    'checks': [{'id': qid, 'probability': report['judgments'][qid]['risk'],
                                                'question': bank[qid]['instructions'] if arm == 'bank' else qid}
                                               for qid in report['shortlist'][:3]],
                                    'unassessed_checks': len(report['unassessed'])})
                    if arm == 'bank':
                        (directory / 'reports').mkdir(exist_ok=True)
                        shutil.copy2(root / 'reports' / f'{c["id"]}.md', directory / 'reports' / f'{c["id"]}.md')
                listing.sort(key=lambda x: -(x['priority'] if x['priority'] is not None else -1))
                write(directory / 'shortlist.json', listing)
            (directory / 'inspect.py').write_text('''import json,pathlib,sys,time
root=pathlib.Path(__file__).resolve().parent
case=sys.argv[1]
assert len(case)==8 and all(c in '0123456789abcdef' for c in case)
assert case in {r['id'] for r in json.loads((root/'changes.json').read_text())}
log=root/'inspections.jsonl'
prior=[json.loads(s) for s in log.read_text().splitlines()] if log.exists() else []
assert case not in {r['id'] for r in prior}, 'Already inspected'
assert len(prior)<8, 'Eight-candidate deep inspection budget exhausted'
with log.open('a') as f:f.write(json.dumps({'id':case,'at':time.time()})+'\\n')
print((root/'evidence'/f'{case}.json').read_text())
report=root/'reports'/f'{case}.md'
if report.exists(): print(report.read_text())
''')
            if delivery_audit:
                helper = directory / 'inspect.py'
                source = helper.read_text().replace("assert case not in {r['id'] for r in prior}, 'Already inspected'\n", '')
                source = source.replace("assert len(prior)<8, 'Eight-candidate deep inspection budget exhausted'", "assert case in {r['id'] for r in prior} or len({r['id'] for r in prior})<8, 'Eight distinct candidates exhausted'")
                helper.write_text(source)
            start = 'Read changes.json first.' if arm == 'ordinary' else 'Start with shortlist.json. Reading the whole changes.json inventory is optional; use it when useful.'
            prompt = f'''Review independent proposed Rails application changes. Each ID is a separate snapshot, not one combined change. Your goal is actionable correctness, security, performance, or test-reliability findings supported by source. Do not infer how many defects exist. Distinguish convention preferences from defects.

{start}

Use `python inspect.py ID` to open at most EIGHT distinct candidates deeply. You may stop earlier. You have 180 seconds from your first action. All arms have the same source inventory, evidence and inspection capabilities. Read no files outside this directory. Do not open evidence/ or reports/ directly, inspect helper internals, run app code/tests, browse, use MCP, delegate, or read another session. Do not edit source or file issues. The helper returns the captured full source and any advisory report available in this arm.

When a source-supported finding is ready, immediately emit commentary `FINDING <id>: <mechanism>`. Continue within budget. Record false leads investigated, unassessed IDs and practical limitations. Return the required JSON report. An unassessed candidate is not clean. Probabilities are suggestions for where to look, not explanations or proof. Missing evidence is unknown. Headline Scores describe separate dimensions; they are not defect probabilities. Facts and conventions are separate from defects. You may challenge or ignore the shortlist.
'''
            if delivery_audit:
                prompt += '''\nEvidence delivery requirements: invoke inspect.py for ONE ID per tool call; do not batch candidates, use shell loops, or pipe the first inspection through head/sed. Set the command tool's max_output_tokens to at least 20000 for each inspection. Previously opened IDs may be reread without consuming another distinct-candidate slot. If output is missing or truncated, reread before asserting evidence-dependent facts, using separate pages only as recovery. Report any remaining delivery gap explicitly.\n'''
            (directory / 'prompt.txt').write_text(prompt)
            jobs.append({'name': name, 'arm': arm, 'repeat': repeat, 'directory': str(directory.resolve()), 'inventory_sha256': hashlib.sha256((directory / 'changes.json').read_bytes()).hexdigest()})
    write(root / folder / 'jobs.json', jobs)
    if delivery_audit:
        write(root / folder / 'protocol.json', {'posthoc': True, 'reason': 'Original six runs had incomplete recorded tool output and blocked rereads. This separate comparison changes only evidence delivery/recovery instructions and the distinct-inspection accounting.', 'unchanged': ['question bank', 'Jev captures', 'presentation policy', 'candidate pool', 'order seeds', 'reviewer model/settings', '180/210 second budgets', 'eight distinct inspections'], 'source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()})
    print(json.dumps({'prepared': len(jobs), 'deep_inspection_limit': 8, 'prompt_seconds': 180, 'supervisor_seconds': 210}))


def run(root, delivery_audit=False):
    folder = 'reviewers-delivery' if delivery_audit else 'reviewers'
    def one(job):
        directory = Path(job['directory'])
        if (directory / 'events.jsonl').exists():
            raise ValueError('Refusing to overwrite reviewer events')
        command = ['codex', 'exec', '--json', '--ephemeral', '--skip-git-repo-check', '--sandbox', 'workspace-write', '-c', 'mcp_servers.node_repl.enabled=false', '-C', str(directory), '--output-schema', str((root / folder / 'schema.json').resolve()), '-o', str(directory / 'report.json'), '-']
        started = time.monotonic()
        with (directory / 'stderr.log').open('w') as error, (directory / 'events.jsonl').open('w') as events:
            proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=error, text=True, start_new_session=True)
            proc.stdin.write((directory / 'prompt.txt').read_text())
            proc.stdin.close()
            timer = threading.Timer(210, lambda: os.killpg(proc.pid, signal.SIGTERM) if proc.poll() is None else None)
            timer.start()
            try:
                for line in proc.stdout:
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        event = {'unparsed': line}
                    events.write(json.dumps({'elapsed_seconds': time.monotonic() - started, 'event': event}) + '\n')
                    events.flush()
                code = proc.wait()
            finally:
                timer.cancel()
        result = {**job, 'exit_code': code, 'seconds': time.monotonic() - started}
        write(directory / 'run.json', result)
        print(json.dumps({k: v for k, v in result.items() if k != 'directory'}), flush=True)
        return result
    jobs = read(root / folder / 'jobs.json')
    # Repeat blocks run sequentially; the three conditions in each block run together.
    results = []
    for repeat in (0, 1):
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            results.extend(pool.map(one, [j for j in jobs if j['repeat'] == repeat]))
    write(root / folder / 'runs.json', results)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare', 'run'])
    parser.add_argument('--root', required=True)
    parser.add_argument('--delivery-audit', action='store_true')
    args = parser.parse_args()
    {'prepare': prepare, 'run': run}[args.command](Path(args.root), args.delivery_audit)
