#!/usr/bin/env python3
"""Bind exact cl100k_base counts to the returned context bytes, not Woods estimates."""
import base64
import hashlib
import importlib.metadata
import json
import pathlib
import sys
import tiktoken

report = json.loads(pathlib.Path(sys.argv[1]).read_text())
encoding = tiktoken.get_encoding('cl100k_base')
vocabulary = b''.join(base64.b64encode(token) + b' ' + str(rank).encode() + b'\n'
                      for token, rank in sorted(encoding._mergeable_ranks.items(), key=lambda pair: pair[1]))
vocabulary_sha256 = hashlib.sha256(vocabulary).hexdigest()
assert vocabulary_sha256 == '223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7'
report['tokenizer'] = {'name': 'cl100k_base', 'package': 'tiktoken',
                       'version': importlib.metadata.version('tiktoken'),
                       'vocabulary_url': 'https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken',
                       'vocabulary_sha256': vocabulary_sha256,
                       'pattern': encoding._pat_str,
                       'special_tokens': encoding._special_tokens,
                       'scope': 'returned context only; no prompt, generation, or agent tokens'}
for row in report['results']:
    context = row.pop('context')
    row['context_sha256'] = hashlib.sha256(context.encode()).hexdigest()
    row['actual_context_tokens_cl100k'] = len(encoding.encode(context, disallowed_special=()))
pathlib.Path(__file__).with_name(sys.argv[2] if len(sys.argv) > 2 else 'capture_report.json').write_text(json.dumps(report, indent=2) + '\n')
