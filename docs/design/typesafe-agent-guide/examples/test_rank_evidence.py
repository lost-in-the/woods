"""Offline checks: no network, provider, credential manager or source execution."""
import copy
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import Mock, patch

import rank_evidence as r


class RankEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'fixture'
        shutil.copytree(r.HERE / 'fixture', self.root)
        self.manifest = r.strict_json((self.root / 'manifest.json').read_bytes())
        self.cards = r.cards_from(self.manifest, self.root)
        self.requests = r.batches(self.manifest['task'], self.manifest['request_model'], self.cards)
        self.identity = r.provenance(self.manifest, self.requests, self.manifest['expected_model'])
        self.capture = r.strict_json((self.root / 'replay.json').read_bytes())
        self.response = self.capture['receipts'][0]['response']

    def evaluate(self, fetch):
        return r.evaluate(self.manifest, self.root, fetch, self.identity, synthetic=True)

    def test_default_fixture_is_explicit_synthetic_replay(self):
        result, _ = self.evaluate(r.replay_fetch(self.capture, self.identity))
        self.assertEqual(result['order'], ['C001', 'C002', 'C003'])
        self.assertEqual(result['usage_origin'], 'synthetic_replay')
        self.assertEqual(result['known_usage_sum'], {'input_tokens': 600, 'output_tokens': 60})
        self.assertAlmostEqual(result['estimated_known_input_cost_usd'], 600 * .042 / 1_000_000)

    def test_duplicate_and_nonfinite_json_rejected(self):
        for raw in [b'{"a":1,"a":2}', b'{"a":{"x":1,"x":2}}', b'{"n":NaN}', b'{"n":Infinity}',
                    b'{"n":1e309}', b'{"n":-1e309}']:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                r.strict_json(raw)

    def test_invalid_answers_or_usage_fall_back_without_partial_scores(self):
        bad = []
        for value in [True, False, -0.1, 1.1, '0.9', None]:
            response = copy.deepcopy(self.response)
            response['answers']['C001']['noul'] = value
            bad.append(response)
        for usage in [None, {}, {'input_tokens': True, 'output_tokens': 1},
                      {'input_tokens': -1, 'output_tokens': 1}, {'input_tokens': 1.0, 'output_tokens': 1}]:
            response = copy.deepcopy(self.response); response['usage'] = usage; bad.append(response)
        response = copy.deepcopy(self.response); response['model'] = 'unexpected'; bad.append(response)
        response = copy.deepcopy(self.response); del response['answers']['C003']; bad.append(response)
        response = copy.deepcopy(self.response); response['answers']['extra'] = {'type':'noul','noul':.5}; bad.append(response)
        response = copy.deepcopy(self.response); response['answers']['C001']['type'] = 'score'; bad.append(response)
        for response in bad:
            with self.subTest(response=response):
                result, _ = self.evaluate(lambda _payload: r.wire(response))
                self.assertEqual(result['status'], 'fallback')
                self.assertEqual(result['scores'], {})
                self.assertEqual(result['order'], [c['id'] for c in r.baseline_order(self.manifest['task'],self.cards)])
        for value in [float('inf'), float('nan')]:
            response = copy.deepcopy(self.response); response['answers']['C001']['noul'] = value
            with self.assertRaises(r.ProviderFailure):
                r.validate_response(self.requests[0], response, self.manifest['expected_model'])

    def test_malformed_response_retains_unknown_usage_not_invented_zero_cost(self):
        result, receipts = self.evaluate(lambda _payload: b'{"usage":{},"usage":{}}')
        self.assertEqual(result['status'], 'fallback')
        self.assertFalse(result['usage_complete'])
        self.assertEqual(result['raw_known_usage'], [])
        self.assertIsNone(receipts['receipts'][0]['known_usage'])

    def test_valid_usage_retained_when_model_or_answer_invalid(self):
        response = copy.deepcopy(self.response); response['model'] = 'other'
        result, _ = self.evaluate(lambda _payload:r.wire(response))
        self.assertEqual(result['raw_known_usage'], [self.response['usage']])
        self.assertTrue(result['usage_complete'])

    def test_enormous_integer_probabilities_fall_back_with_known_usage(self):
        for value in [10**400, -(10**400)]:
            response = copy.deepcopy(self.response)
            response['answers']['C001']['noul'] = value
            with self.subTest(value_sign=value > 0):
                result, _ = self.evaluate(lambda _payload: r.wire(response))
                self.assertEqual(result['status'], 'fallback')
                self.assertEqual(result['reason'], 'invalid_noul')
                self.assertEqual(result['raw_known_usage'], [self.response['usage']])

    def test_usage_local_bound_prevents_overflow_and_preserves_boundary(self):
        # One billion per counter/request is a local safety cap, not a service limit.
        for field in ['input_tokens', 'output_tokens']:
            for value in [1_000_000_001, 10**400]:
                response = copy.deepcopy(self.response)
                response['usage'][field] = value
                with self.subTest(field=field, enormous=value > 10**300):
                    result, _ = self.evaluate(lambda _payload: r.wire(response))
                    self.assertEqual(result['status'], 'fallback')
                    self.assertEqual(result['reason'], 'invalid_usage')
                    self.assertEqual(result['raw_known_usage'], [])
                    self.assertFalse(result['usage_complete'])
                    r.wire(result)  # Always serializable without infinity.
        response = copy.deepcopy(self.response)
        response['usage'] = {'input_tokens': 1_000_000_000, 'output_tokens': 1_000_000_000}
        result, _ = self.evaluate(lambda _payload: r.wire(response))
        self.assertEqual(result['status'], 'ranked')
        self.assertAlmostEqual(result['estimated_known_input_cost_usd'], 42)

    def test_malformed_local_containers_stop_as_json_before_fetch(self):
        malformed = [('manifest', value) for value in [None, [], 1, 'manifest']]
        for candidates in [None, {}, [None], [[]]]:
            manifest = copy.deepcopy(self.manifest)
            manifest['candidates'] = candidates
            malformed.append(('manifest', manifest))
        malformed += [('capture', value) for value in [None, [], 1, 'capture']]
        for row in [None, [], {'status': 'validated', 'response': None,
                               'request_sha256': self.identity['request_sha256'][0]}]:
            capture = copy.deepcopy(self.capture)
            capture['receipts'] = [row]
            malformed.append(('capture', capture))
        for kind, value in malformed:
            manifest_path = self.root / 'manifest.json'
            capture_path = self.root / 'replay.json'
            manifest_path.write_bytes(r.wire(value if kind == 'manifest' else self.manifest))
            capture_path.write_bytes(r.wire(value if kind == 'capture' else self.capture))
            with self.subTest(kind=kind, value=value), patch('sys.argv', [
                    'rank_evidence.py', '--manifest', str(manifest_path), '--capture', str(capture_path)]), \
                    patch.object(r, 'evaluate') as evaluate, patch('sys.stdout', new_callable=io.StringIO) as output:
                self.assertEqual(r.main(), 2)
                self.assertEqual(json.loads(output.getvalue())['status'], 'stopped')
                evaluate.assert_not_called()

    def test_final_freshness_read_errors_keep_usage_in_cli_json(self):
        original = r.cards_from
        for error in [OSError('private path'), ValueError('private schema'),
                      KeyError('private key'), TypeError('private type')]:
            calls = []
            def cards(*args):
                calls.append(None)
                if len(calls) == 4:  # Main, evaluation, pre-request, final freshness.
                    raise error
                return original(*args)
            with self.subTest(error=type(error).__name__), patch('sys.argv', [
                    'rank_evidence.py', '--manifest', str(self.root / 'manifest.json'),
                    '--capture', str(self.root / 'replay.json')]), patch.object(r, 'cards_from', side_effect=cards), \
                    patch('sys.stdout', new_callable=io.StringIO) as output:
                self.assertEqual(r.main(), 2)
                result = json.loads(output.getvalue())
                self.assertEqual(result['status'], 'stopped')
                self.assertEqual(result['raw_known_usage'], [self.response['usage']])
                self.assertAlmostEqual(result['estimated_known_input_cost_usd'], 600 * .042 / 1_000_000)
                self.assertNotIn('private', output.getvalue())

    def test_full_vector_fallback_after_later_batch_failure_stops_calls(self):
        calls = []
        # Make three legal batches without changing production cap/policy.
        for card in self.cards:
            card['source_code'] += '\n# padding' * 1800
        requests = r.batches(self.manifest['task'],self.manifest['request_model'],self.cards)
        self.assertGreater(len(requests),1)
        identity = r.provenance(self.manifest, requests, self.manifest['expected_model'])
        def fetch(payload):
            calls.append(payload)
            if len(calls)==2:
                raise r.ProviderFailure('http_429')
            req=r.strict_json(payload)
            return r.wire({'model':self.manifest['expected_model'], 'answers':{
                cid:{'type':'noul','noul':.9} for cid in req['questions']}, 'usage':{'input_tokens':10,'output_tokens':2}})
        with patch.object(r,'cards_from',return_value=self.cards):
            result, _=r.evaluate(self.manifest,self.root,fetch,identity)
        self.assertEqual(len(calls),2)
        self.assertEqual(result['status'],'fallback')
        self.assertEqual(result['scores'],{})
        self.assertEqual(result['order'],[c['id'] for c in r.baseline_order(self.manifest['task'],self.cards)])
        self.assertEqual(result['known_usage_sum']['input_tokens'],10)
        self.assertFalse(result['usage_complete'])

    def test_stale_source_stops_before_call(self):
        (self.root/'source/catalog.py').write_text('changed')
        fetch=Mock()
        with self.assertRaisesRegex(r.Stopped,'invalid_source_span|stale_source'):
            self.evaluate(fetch)
        fetch.assert_not_called()

    def test_stale_index_stops(self):
        (self.root/'index.json').write_text('changed generation')
        with self.assertRaisesRegex(r.Stopped,'stale_index'):
            self.evaluate(Mock())

    def test_source_changes_during_response_discard_ranking_retain_usage(self):
        def fetch(_payload):
            path=self.root/'source/catalog.py';path.write_bytes(path.read_bytes()+b'\n# changed')
            return r.wire(self.response)
        with self.assertRaisesRegex(r.Stopped,'stale_source') as raised:
            self.evaluate(fetch)
        self.assertEqual(raised.exception.known_usage,[self.response['usage']])

    def test_cross_file_or_wrong_offset_source_cannot_impersonate_card(self):
        for change in [{'file_path':'source/retries.py'}, {'start_byte':0}]:
            manifest=copy.deepcopy(self.manifest);manifest['candidates'][0].update(change)
            with self.subTest(change=change),self.assertRaises(r.Stopped):
                r.cards_from(manifest,self.root)

    def test_traversal_and_symlink_rejected(self):
        for path in ['../source/catalog.py','/etc/passwd','source/../catalog.py']:
            with self.subTest(path=path),self.assertRaises(r.Stopped):
                r.local_file(self.root,path)
        try:
            (self.root/'link.py').symlink_to(self.root/'source/catalog.py')
        except (OSError,NotImplementedError):
            return  # Only the symlink branch is inapplicable on such filesystems.
        with self.assertRaisesRegex(r.Stopped,'symlink'):
            r.local_file(self.root,'link.py')

    def test_windows_drive_and_stream_paths_are_lexically_rejected(self):
        from pathlib import PurePosixPath, PureWindowsPath
        base = PureWindowsPath('D:/snapshot')
        self.assertEqual(str(base / PurePosixPath('C:/outside.py')), 'C:\\outside.py')
        for name in ['C:/outside.py', 'C:outside.py', 'source/catalog.py:secret']:
            with self.subTest(name=name), self.assertRaisesRegex(r.Stopped, 'invalid_source_path'):
                r.local_file(self.root, name)

    def test_allowlist_and_cap(self):
        cards=copy.deepcopy(self.cards)
        cards[0]['private_label']='DO_NOT_TRANSMIT'
        cards[0]['reference_patch']='DO_NOT_TRANSMIT'
        encoded=r.wire(r.request_for(self.manifest['task'],self.manifest['request_model'],cards))
        self.assertNotIn(b'DO_NOT_TRANSMIT',encoded)
        self.assertNotIn(b'file_sha256',encoded)
        for req in self.requests:self.assertLessEqual(len(r.wire(req)),24*1024)
        cards[0]['source_code']='x'*(24*1024)
        with self.assertRaisesRegex(r.Stopped,'candidate_exceeds'):
            r.batches(self.manifest['task'],self.manifest['request_model'],cards)

    def test_exact_replay_identity_and_order(self):
        for field,value in [('expected_returned_model','other'),('rubric_version','changed'),('index_generation','new')]:
            capture=copy.deepcopy(self.capture);capture['provenance'][field]=value
            with self.subTest(field=field),self.assertRaisesRegex(r.Stopped,'identity'):
                r.replay_fetch(capture,self.identity)
        capture=copy.deepcopy(self.capture);capture['receipts'][0]['request_sha256']='0'*64
        with self.assertRaisesRegex(r.Stopped,'request'):
            r.replay_fetch(capture,self.identity)
        capture=copy.deepcopy(self.capture);capture['receipts']=[]
        with self.assertRaisesRegex(r.Stopped,'missing'):
            r.replay_fetch(capture,self.identity)

    def test_replay_rejects_invalid_later_receipts_before_any_fetch(self):
        for card in self.cards:
            card['source_code'] += '\n# padding' * 1800
        requests = r.batches(self.manifest['task'], self.manifest['request_model'], self.cards)
        self.assertEqual(len(requests), 3)
        identity = r.provenance(self.manifest, requests, self.manifest['expected_model'])
        capture = {'format': 1, 'provenance': identity, 'receipts': [
            {'request_sha256': digest, 'status': 'validated', 'response': {}}
            for digest in identity['request_sha256']]}
        for malformed in [None, {'status': 'not-a-status'}, {'status': 'validated', 'response': None}]:
            changed = copy.deepcopy(capture)
            changed['receipts'][1] = malformed
            if isinstance(malformed, dict):
                malformed['request_sha256'] = identity['request_sha256'][1]
            with self.subTest(malformed=malformed), self.assertRaises(r.Stopped):
                r.replay_fetch(changed, identity)

    def test_replay_failure_must_be_terminal_and_can_end_early(self):
        identity = copy.deepcopy(self.identity)
        identity['request_sha256'] *= 3
        first = {'request_sha256': identity['request_sha256'][0], 'status': 'failed', 'known_usage': None}
        capture = {'format': 1, 'provenance': identity, 'receipts': [first]}
        fetch = r.replay_fetch(capture, identity)
        with self.assertRaises(r.ProviderFailure):
            fetch(r.wire(self.requests[0]))
        capture['receipts'] += [copy.deepcopy(self.capture['receipts'][0])] * 2
        with self.assertRaises(r.Stopped):
            r.replay_fetch(capture, identity)

    def test_replay_preflights_later_response_serialization(self):
        identity = copy.deepcopy(self.identity)
        identity['request_sha256'] *= 3
        for extra in [float('inf'), '\ud800']:
            capture = {'format': 1, 'provenance': identity, 'receipts': [
                copy.deepcopy(self.capture['receipts'][0]) for _ in range(3)]}
            capture['receipts'][1]['response']['unexpected_extra'] = extra
            with self.subTest(extra=repr(extra)), self.assertRaisesRegex(r.Stopped, 'invalid_replay_response'):
                r.replay_fetch(capture, identity)

    def test_ties_are_deterministic_and_low_scores_do_not_filter(self):
        response=copy.deepcopy(self.response)
        for answer in response['answers'].values():answer['noul']=.01
        result,_=self.evaluate(lambda _payload:r.wire(response))
        self.assertEqual(result['status'],'ranked')
        self.assertEqual(result['order'],['C001','C002','C003'])

    def test_redirect_and_transport_errors_are_sanitized_without_retry(self):
        for status in [301,302,401,429,529]:
            connection=Mock();connection.getresponse.return_value.status=status
            with patch.object(r.http.client,'HTTPSConnection',return_value=connection):
                with self.assertRaises(r.ProviderFailure) as raised:
                    r.live_fetch('SYNTHETIC_SECRET')(b'{}')
            self.assertEqual(raised.exception.category,f'http_{status}')
            connection.request.assert_called_once();connection.close.assert_called_once()
            connection.getresponse.return_value.read1.assert_not_called()
        connection=Mock();connection.connect.side_effect=OSError('SYNTHETIC_SECRET in error')
        with patch.object(r.http.client,'HTTPSConnection',return_value=connection):
            with self.assertRaises(r.ProviderFailure) as raised:r.live_fetch('SYNTHETIC_SECRET')(b'{}')
        self.assertEqual(raised.exception.category,'transport_failure')

    def test_oversize_response_cannot_rank(self):
        result,_=self.evaluate(lambda _payload:b' '*(r.RESPONSE_CAP+1))
        self.assertEqual(result['status'],'fallback')
        self.assertEqual(result['reason'],'response_too_large')

    def test_mock_https_success_encoding_and_body_limits(self):
        connection=Mock();response=connection.getresponse.return_value
        response.status=200;response.getheader.return_value='identity'
        response.read1.side_effect=[b'{"ok":true}', b'']
        with patch.object(r.http.client,'HTTPSConnection',return_value=connection) as factory:
            self.assertEqual(r.live_fetch('SYNTHETIC_SECRET')(b'{}'),b'{"ok":true}')
        self.assertEqual(factory.call_args.args,('api.typesafe.ai',443))
        self.assertEqual(factory.call_args.kwargs['timeout'],5)
        self.assertEqual(connection.request.call_args.args,('POST','/v1/systemone'))
        response.getheader.return_value='gzip';response.read1.reset_mock()
        with patch.object(r.http.client,'HTTPSConnection',return_value=connection):
            with self.assertRaises(r.ProviderFailure) as raised:r.live_fetch('SYNTHETIC_SECRET')(b'{}')
        self.assertEqual(raised.exception.category,'unexpected_content_encoding')
        response.read1.assert_not_called()
        response.getheader.return_value='identity';response.read1.side_effect=[b'x'*(r.RESPONSE_CAP+1)]
        with patch.object(r.http.client,'HTTPSConnection',return_value=connection):
            with self.assertRaises(r.ProviderFailure) as raised:r.live_fetch('SYNTHETIC_SECRET')(b'{}')
        self.assertEqual(raised.exception.category,'response_too_large')

    def test_utf8_coordinates_are_bytes_and_split_characters_are_rejected(self):
        path=self.root/'source/catalog.py';raw='café = 1\n'.encode('utf-8');path.write_bytes(raw)
        manifest=copy.deepcopy(self.manifest);manifest['candidates']=manifest['candidates'][:1]
        item=manifest['candidates'][0];item.update(start_byte=0,end_byte=len(raw),file_sha256=r.sha(raw),source_sha256=r.sha(raw))
        self.assertEqual(r.cards_from(manifest,self.root)[0]['source_code'],'café = 1\n')
        item.update(start_byte=4,source_sha256=r.sha(raw[4:]))
        with self.assertRaises(UnicodeError):r.cards_from(manifest,self.root)

    def test_cli_default_has_no_environment_or_transport_access(self):
        with patch('sys.argv',['rank_evidence.py']),patch.object(r,'live_fetch') as transport,\
             patch.object(r.os.environ,'pop',side_effect=AssertionError('offline credential access')),\
             patch('sys.stdout',new_callable=io.StringIO) as output:
            self.assertEqual(r.main(),0)
        transport.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['usage_origin'],'synthetic_replay')

    def test_live_reads_environment_once_and_reuses_client(self):
        with patch('sys.argv',['rank_evidence.py','--live','--request-model','jev-1.13.0','--expected-model','jev-1.13.0']),\
             patch.object(r.os.environ,'pop',return_value='SYNTHETIC_SECRET') as read,\
             patch.object(r,'live_fetch',return_value=lambda _payload:r.wire(self.response)) as factory,\
             patch('sys.stdout',new_callable=io.StringIO) as output:
            self.assertEqual(r.main(),0)
        read.assert_called_once_with('TYPESAFE_API_KEY',None);factory.assert_called_once_with('SYNTHETIC_SECRET')
        self.assertNotIn('SYNTHETIC_SECRET',output.getvalue())


if __name__=='__main__':
    unittest.main()
