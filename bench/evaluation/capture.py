#!/usr/bin/env python3
"""Optional maintenance capture; CI only replays reviewed vectors, never downloads models.

uv venv /tmp/woods-eval-venv
uv pip install --python /tmp/woods-eval-venv/bin/python -r bench/evaluation/requirements.txt
/tmp/woods-eval-venv/bin/python bench/evaluation/capture.py /tmp/woods-eval-model
"""
import hashlib
import importlib.metadata
import json
import pathlib
import subprocess
import sys
import time

from fastembed import TextEmbedding
from huggingface_hub import snapshot_download

ROOT = pathlib.Path(__file__).resolve().parent
MODEL = "sentence-transformers/all-MiniLM-L6-v2"
REPO = "qdrant/all-MiniLM-L6-v2-onnx"
REVISION = "5f1b8cd78bc4fb444dd171e59b18f3a3af89a079"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def capture(cache):
    folder = pathlib.Path(snapshot_download(REPO, revision=REVISION, cache_dir=cache,
                          allow_patterns=["model.onnx", "config.json", "tokenizer.json",
                                          "tokenizer_config.json", "special_tokens_map.json"]))
    model = TextEmbedding(MODEL, specific_model_path=str(folder), threads=2)
    model.model.tokenizer.enable_truncation(max_length=512)
    texts = json.loads(subprocess.check_output(
        ["bundle", "exec", "ruby", "-Ilib", str(ROOT / "runner.rb"), "--inputs"], text=True))
    list(model.embed(["warm up"]))
    start = time.perf_counter()
    embeddings = list(model.embed(texts, batch_size=8))
    elapsed = (time.perf_counter() - start) * 1000
    token_counts = [sum(model.model.tokenizer.encode(text).attention_mask) for text in texts]
    report = {
        "schema_version": 1, "corpus_sha256": sha((ROOT / "corpus.json").read_bytes()),
        "model": MODEL, "model_repository": REPO, "model_revision": REVISION,
        "license": "Apache-2.0", "dimensions": 384, "max_input_tokens": 512,
        "files_sha256": {p.name: sha(p.read_bytes()) for p in sorted(folder.iterdir()) if p.is_file()},
        "packages": {name: importlib.metadata.version(name) for name in
                     ["fastembed", "onnxruntime", "tokenizers", "numpy"]},
        "embedding_capture": {"texts": len(texts), "batch_size": 8, "threads": 2,
                              "elapsed_ms": elapsed, "input_tokens": sum(token_counts),
                              "tokens_per_text": token_counts, "includes_download_or_warmup": False},
        "vectors": {sha(text.encode()): vector.tolist() for text, vector in zip(texts, embeddings)},
    }
    (ROOT / "vectors.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["embedding_capture"], indent=2))


if __name__ == "__main__":
    capture(sys.argv[1])
