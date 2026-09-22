import argparse
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import runner


class MarkdownTests(unittest.TestCase):
    def test_heading_like_code_and_crlf_are_preserved(self):
        raw = '# Intro\r\n\r\n```ruby\r\n## Not a heading\r\nputs "é"\r\n```\r\n\r\n## Real\r\nText\r\n'.encode()
        sections = runner.sections(raw)
        self.assertEqual(['Intro', 'Real'], [s['heading'] for s in sections])
        self.assertEqual(raw, ''.join(s['text'] for s in sections).encode())
        self.assertEqual(8, sections[1]['start_line'])
        blocks = runner.blocks(sections[0])
        self.assertTrue(any('## Not a heading' in b['text'] and b['text'].count('```') == 2 for b in blocks))

    def test_tilde_fence_requires_matching_close_and_unclosed_refuses(self):
        text = '# Top\n~~~~\n## code\n```\n~~~~\n## End\n'
        self.assertEqual(['Top', 'End'], [s['heading'] for s in runner.sections(text.encode())])
        with self.assertRaisesRegex(ValueError, 'unclosed_fence'):
            runner.sections(b'# Top\n```\n## code\n')

    def test_child_section_is_explicit_not_silently_included_with_parent(self):
        result = runner.sections(b'# Page\nIntro\n## Parent\nSetup\n### Child\nDetail\n')
        self.assertEqual('## Parent\nSetup\n', result[1]['text'])
        self.assertEqual(['Page', 'Parent'], result[2]['ancestors'])


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.source = self.base / 'source'
        self.source.mkdir()
        (self.source / 'guide.md').write_text('# Guide\nHello\n\n## Setup\nRun the command.\n')
        (self.source / 'impl.rb').write_text('MODE = :safe\n')
        self.plan = self.base / 'plan.json'
        self.plan.write_text(json.dumps({'revision': 'a' * 40, 'pages': [{'path': 'guide.md', 'sections': ['Setup'], 'audience': 'developer', 'purpose': 'Setup', 'evidence': [{'path': 'impl.rb'}]}]}))
        self.root = self.base / 'out'
        self.args = argparse.Namespace(root=str(self.root), source=str(self.source), plan=str(self.plan))

    def tearDown(self):
        self.tmp.cleanup()

    def prepare(self):
        with patch.object(runner, 'git', side_effect=lambda root, *args: 'a' * 40 if args[0] == 'rev-parse' else ''), contextlib.redirect_stdout(io.StringIO()):
            runner.prepare(self.args)

    def test_frozen_source_change_and_request_tampering_stop(self):
        self.prepare()
        with patch.object(runner, 'git', return_value='a' * 40):
            runner.verify_source(self.root, self.source)
            (self.source / 'impl.rb').write_text('MODE = :unsafe\n')
            with self.assertRaisesRegex(ValueError, 'source_changed'):
                runner.verify_source(self.root, self.source)
        request = self.root / 'requests/D001.json'
        request.write_bytes(request.read_bytes() + b' ')
        with self.assertRaisesRegex(ValueError, 'frozen_input_changed'):
            runner.transport.verify_inputs(self.root)

    def test_no_silent_truncation_for_large_source_or_missing_section(self):
        (self.source / 'impl.rb').write_text('x' * 31_000)
        with self.assertRaisesRegex(ValueError, 'request_too_large'):
            self.prepare()
        self.assertFalse(self.root.exists())
        (self.source / 'impl.rb').write_text('safe\n')
        plan = json.loads(self.plan.read_text())
        plan['pages'][0]['sections'] = ['Absent']
        self.plan.write_text(json.dumps(plan))
        with self.assertRaisesRegex(ValueError, 'missing_heading'):
            self.prepare()

    def test_missing_evidence_is_not_converted_to_pass_and_missing_answers_count(self):
        self.prepare()
        q = runner.read(self.root / 'requests/D001.json')['questions']['accuracy_status']
        answer = {'type': 'choice', 'choice': 'missing_evidence', 'confidence': 1.0,
                  'probabilities': {k: float(k == 'missing_evidence') for k in q['criteria']}}
        response = {'model': runner.MODEL, 'answers': {'accuracy_status': answer}, 'usage': {'input_tokens': 100, 'output_tokens': 10}}
        runner.write(self.root / 'responses/D001.json', response)
        runner.write(self.root / 'capture.json', {'attempts': [{'id': 'D001', 'status': 'partial_invalid', 'http_status': 200,
                     'response': 'responses/D001.json', 'response_sha256': runner.sha((self.root / 'responses/D001.json').read_bytes()),
                     'usage': response['usage']}]})
        with contextlib.redirect_stdout(io.StringIO()):
            runner.summarize(self.args)
        result = runner.read(self.root / 'summary.json')
        self.assertEqual(7, result['questions_expected'])
        self.assertEqual(1, result['questions_valid'])
        self.assertEqual('unassessed_missing_evidence', result['rows'][0]['accuracy_assessment'])
        self.assertEqual(100, result['usage']['input_tokens'])
        (self.root / 'responses/D001.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'response_changed'):
            runner.summarize(self.args)

    def test_paths_and_duplicate_json_refuse(self):
        with self.assertRaisesRegex(ValueError, 'unsafe_path'):
            runner.safe_path(self.source, '../private')
        (self.source / 'linked').symlink_to(self.plan)
        with self.assertRaisesRegex(ValueError, 'symlink_source'):
            runner.safe_path(self.source, 'linked')
        bad = self.base / 'bad.json'
        bad.write_text('{"x":1,"x":2}')
        with self.assertRaisesRegex(ValueError, 'duplicate_json_key'):
            runner.read(bad)


if __name__ == '__main__':
    unittest.main()
