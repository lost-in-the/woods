#!/usr/bin/env python3
"""Versioned, post-capture section applicability correction; no new inference."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import shutil

VERSION = '2026-09-21.2'


def excluded_questions(state, catalog):
    """Apply explicit path-scoped section premises, independently of answers."""
    changed = state['changed']
    tests = any(p.startswith(('spec/', 'test/')) for p in changed)
    views = any(p.startswith(('app/views/', 'app/helpers/', 'app/components/', 'app/javascript/controllers/')) or p.endswith(('.erb', '.haml', '.slim')) for p in changed)
    result = {}
    for q in catalog['questions']:
        if q['section'] == 'tests' and not tests and q['id'] not in ('test_coverage_of_change', 'test_regression_for_fix'):
            result[q['id']] = 'Tests section explicitly runs on test files in the diff; this diff changes none.'
        if q['section'] == 'views' and not views:
            result[q['id']] = 'Views section explicitly runs on views/helpers/components/Stimulus changes; none is in this diff.'
    return result


def apply(root):
    original = root / 'summary-initial.json'
    if original.exists():
        raise ValueError('Applicability correction already applied; originals must not be overwritten')
    shutil.copy2(root / 'summary.json', original)
    shutil.copytree(root / 'reports', root / 'reports-initial')
    summary = json.loads(original.read_text())
    catalog = json.loads((root / 'catalog.json').read_text())
    audit = {'interpretation_version': VERSION, 'post_capture': True,
             'reason': 'First development callback report contained a test-only check despite no changed tests; section applicability was missing from the initial interpreter.',
             'scope': 'Deterministic Tests/Views path premises from the supplied bank; independent of answers, labels, target IDs or thresholds. Coverage absence and regression-for-fix retain their own meanings. Observability lexical applicability remains unimplemented, explicitly unknown.',
             'source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
             'original_summary_sha256': hashlib.sha256(original.read_bytes()).hexdigest(), 'cases': {}}
    for report in summary['reports']:
        if report['arm'] != 'bank':
            continue
        cid = report['case_id']
        excluded = excluded_questions(json.loads((root / 'packets' / f'{cid}.json').read_text()), catalog)
        audit['cases'][cid] = excluded
        for qid, reason in excluded.items():
            if qid in report['judgments']:
                j = report['judgments'][qid]
                j['original_evidence'] = copy.deepcopy(j['evidence'])
                j['evidence'] = {'status': 'not_applicable', 'missing': {}, 'reason': reason}
        report['shortlist'] = [qid for qid in report['shortlist'] if qid not in excluded]
        report['likely'] = [qid for qid in report['likely'] if qid not in excluded]
        report['unassessed'] = [qid for qid in report['unassessed'] if qid not in excluded]
        report['not_applicable'] = sorted(excluded)
        eligible = [j['risk'] for j in report['judgments'].values() if j['kind'] == 'defect' and j['type'] == 'noul' and j['complete_repeats'] and j['evidence']['status'] == 'supplied']
        report['priority'] = max(eligible, default=None)
        source = (root / 'reports-initial' / f'{cid}.md').read_text().splitlines()
        lines = []
        for line in source:
            ids = re.findall(r'`([^`]+)`', line)
            if line.startswith('- ') and any(qid in excluded for qid in ids):
                continue
            lines.append(line)
        lines += ['', '## Section applicability', '',
                  'Presentation interpretation ' + VERSION + ' corrects missing section premises after capture; raw requests, answers, initial reports and initial summary are unchanged.',
                  'Observability section applicability has not been resolved; treat those signals as provisional.', '']
        lines += [f'- `{qid}`: not applicable — {reason}' for qid, reason in excluded.items()]
        (root / 'reports' / f'{cid}.md').write_text('\n'.join(lines) + '\n')
    summary['presentation_interpretation'] = audit
    (root / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    (root / 'presentation-audit.json').write_text(json.dumps(audit, indent=2) + '\n')
    print(json.dumps({'version': VERSION, 'cases': len(audit['cases']), 'excluded_checks': sum(len(v) for v in audit['cases'].values())}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True)
    args = parser.parse_args()
    apply(Path(args.root))
