# Embedding Models

Woods supports OpenAI's embedding API and any model served by a local Ollama
instance. This doc covers the Ollama side — which model to pick, why the
default is conservative, and how to add a new one.

## TL;DR

| Model | Native context | Dimensions | Size on disk | Recommended for |
|---|---|---|---|---|
| `nomic-embed-text` (default) | 2048 | 768 | 274 MB | General use, small footprint |
| `bge-m3` | **8192** | 1024 | 1.2 GB | Large Rails units, fewer chunks |
| `snowflake-arctic-embed2` | 8192 | 1024 | 1.2 GB | Multilingual projects |
| `mxbai-embed-large` | 512 | 1024 | 670 MB | Short text (tweets, commit msgs) |
| `all-minilm` | 512 | 384 | 46 MB | Tight-memory environments |

The default is `nomic-embed-text` because it's small, fast, and ships with every
fresh Ollama install. If you're indexing a large Rails codebase and don't mind
pulling a bigger model, switching to `bge-m3` usually gives you:

- **Fewer chunks per unit** — 4× the context means most concern-inlined models
  and service objects fit in a single embedding, which keeps retrieval scores
  cleaner and the vector index smaller.
- **Stronger retrieval** — `bge-m3` benchmarks meaningfully better than
  `nomic-embed-text` on code-search MTEB tasks.

The tradeoff is download size (1.2 GB vs 274 MB), RAM usage during inference,
and a dimension change (768 → 1024) that requires re-indexing when you switch.

## Switching models

```ruby
Woods.configure do |config|
  config.embedding_provider = :ollama
  config.embedding_options = {
    model: 'bge-m3',
    host: 'http://localhost:11434'
  }
  # Everything else — chunker sizing, token counting, num_ctx — is picked
  # up automatically from the model name.
end
```

Pull the model first:

```bash
ollama pull bge-m3
```

If you switch models on an existing install, drop your vector index before
re-indexing — the embedding dimension change is incompatible with existing
vectors. Woods raises `Woods::MCP::DimensionMismatch` if you miss it:
`rake woods:embed` refuses up front on pgvector/Qdrant, and the MCP server
refuses at boot when a dump's recorded dimension disagrees with the provider.

## Why `num_ctx` isn't enough

Ollama has a long-running regression (upstream issue
[ollama/ollama#14186](https://github.com/ollama/ollama/issues/14186)) where
`options.num_ctx` does **not** lift the effective context ceiling on
`/api/embed` for models whose native context is smaller than the requested
override. For `nomic-embed-text` (native 2048) the server rejects inputs above
that with a `400 "the input length exceeds the context length"` regardless of
`num_ctx`.

Woods works around this two ways:

1. **Advertise the native ceiling, not the override.** `Provider::Ollama` keeps
   a model → native-context registry (`MODEL_CONTEXT_LENGTHS`) so the chunker
   sizes inputs to what Ollama will actually accept. `num_ctx` is still passed
   through the request body in case the regression is fixed upstream, but
   nothing relies on it.
2. **Verify client-side with the real tokenizer.** When the
   [`tokenizers`](https://github.com/ankane/tokenizers-ruby) gem is installed,
   `Embedding::TokenCounter` loads the `bert-base-uncased` WordPiece tokenizer
   (the one every BERT-family embedding model is built on) and the chunker
   re-verifies every slice. WordPiece fragments CamelCase and `::` separators
   differently than character-based estimation suggests — this verification is
   what catches the 10–20 % gap between our estimate and Ollama's internal
   count.

## Adding a new model to the registry

If you want Woods to auto-pick `num_ctx` for a model we don't ship support for:

1. Pull the model: `ollama pull your-model`.
2. Read its native context:
   ```bash
   curl -s http://localhost:11434/api/show -d '{"model":"your-model"}' \
     | jq '.model_info | to_entries[] | select(.key | contains("context_length"))'
   ```
3. Verify the server actually honours it (some models report a larger context
   than the server enforces — see the nomic-embed-text case above). Send a
   request with a known-large input and check for 400s:
   ```bash
   curl -s http://localhost:11434/api/embed \
     -d "{\"model\":\"your-model\",\"input\":\"$(ruby -e 'print "word " * 8500')\"}" \
     | jq '.error // "no error — context held"'
   ```
4. Add it to `MODEL_CONTEXT_LENGTHS` in `lib/woods/embedding/provider.rb`
   (keep the value at the **enforced** ceiling, not the advertised one).

## When to stay on `nomic-embed-text`

- Fresh installs, CI, evaluation environments — no extra pull step.
- Small/toy codebases where the 2048-token ceiling isn't a real constraint.
- Memory-constrained Ollama hosts (the 1.2 GB `bge-m3` weights vs 274 MB for
  `nomic-embed-text` can matter on a shared laptop).

## When to switch to `bge-m3` or `snowflake-arctic-embed2`

- Indexing a real-world Rails app where concern-inlined models or long service
  objects routinely exceed 2048 tokens.
- You already pay the `tokenizers` gem install cost and want the tighter
  coupling between client-side verification and server-side enforcement.
- Multilingual content (Arctic Embed 2 is BGE M3 with a stronger non-English
  story).

## Deterministic fake provider (no model at all)

For CI, sandboxes, and offline hosts where neither OpenAI nor Ollama is
reachable, `config.embedding_provider = :fake` wires
`Woods::Embedding::Provider::Fake` — deterministic bag-of-words hashing with
L2 normalization, no network endpoint, configurable dimension
(`embedding_options = { dims: 128 }`). Cosine similarity stays mechanically
meaningful (shared vocabulary ranks closer), but the vectors are **not
semantically meaningful embeddings**: use it to smoke-test the
embed → store → retrieve pipeline, never for production retrieval quality.
See [CONFIGURATION_REFERENCE.md](./CONFIGURATION_REFERENCE.md#fake-embeddings-ci--sandboxes--offline-hosts).

## Related

- [CONFIGURATION_REFERENCE.md](./CONFIGURATION_REFERENCE.md) — full config surface
- [TOKEN_BENCHMARK.md](./TOKEN_BENCHMARK.md) — where our chars/token numbers come from
- [BACKEND_MATRIX.md](./BACKEND_MATRIX.md) — picking a vector store that matches
