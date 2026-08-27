# Token Estimation Benchmark

> **Single source of truth:** `Woods::TokenUtils.chars_per_token_for(provider)`
> in `lib/woods/token_utils.rb`. Production code uses **4.0 chars/token** for
> the OpenAI path and **1.5 chars/token** for the Ollama / WordPiece path.
> Both are applied consistently by `Woods::Builder#chars_per_token_for`,
> `ContextAssembler`, `TextPreparer`, and `ExtractedUnit#estimated_tokens`.
> The cost-model layer (`lib/woods/cost_model/`) is the one exception — it
> uses its own pre-aggregated `TOKENS_PER_CHUNK` constant (450) rather than
> a per-string ratio, since it measures a different thing (per-chunk average
> vs. per-string chars/token).
>
> When the optional [`tokenizers`](https://github.com/ankane/tokenizers-ruby)
> gem is installed, the Ollama path uses the real BERT WordPiece tokenizer
> (`Woods::Embedding::TokenCounter`) instead of this heuristic. The 4.0
> divisor below is what the gem falls back to everywhere else.

This is a historical record of the benchmark that picked 4.0 over the
original 3.5 divisor. It is cited from five places in `lib/` as the evidence
for that choice — keep the numbers below intact if you edit this doc.

## What was measured

- **Corpus**: 19 Ruby source files from `lib/woods/` (1.4 KB–33.4 KB): extractors, retrieval pipeline, MCP servers, and utility modules.
- **Reference tokenizer**: tiktoken_ruby with cl100k_base (GPT-4) and o200k_base (GPT-4o).
- **Heuristic under test**: `(content.length / N).ceil`, comparing divisors 3.0–4.0.

## Results

| Divisor | Mean Abs Error (cl100k) | Max Abs Error |
|--------:|------------------------:|--------------:|
| 3.0 | 47.2% | 80.5% |
| 3.2 | 38.0% | 69.2% |
| 3.5 (previous default) | 26.2% | 54.7% |
| 3.8 | 16.2% | 42.5% |
| **4.0 (shipped)** | **10.6%** | **35.4%** |

Mean chars/token across the corpus was **4.41** (range 3.94–5.42). The
heuristic always overestimated — never underestimated — across all 19 files,
which is what makes it safe for token-limit enforcement even at its worst
case. Code lines and comment/YARD lines had similar ratios (4.38 vs. 4.27
chars/token) — no separate handling needed for either.

## What shipped

**The divisor changed from 3.5 to 4.0.** It roughly halves the mean
overestimate (26.2% → 10.6%) while keeping the conservative
always-overestimates property, at zero new runtime dependencies. The
constant lives in one place now (`Woods::TokenUtils::CHARS_PER_TOKEN_BY_PROVIDER`),
not scattered across call sites — see `lib/woods/token_utils.rb` for the
current definition and `docs/EMBEDDING_MODELS.md` for the Ollama-side ratio.

**tiktoken_ruby was deliberately not added as a runtime dependency.** A 10.6%
mean error is acceptable for chunking decisions, budget estimates, and
truncation; a native-extension dependency for marginal accuracy gains wasn't
worth it. The optional `tokenizers` gem covers the case where exact counts
matter more (see above).

## Reproducing this benchmark

```bash
gem install tiktoken_ruby  # not a Gemfile dependency — benchmark only
```

`spec/token_estimation_benchmark_spec.rb` keeps this honest going forward: it
checks the heuristic is self-consistent (monotonically increasing with
content length) and, when tiktoken_ruby is installed, that overestimation
stays bounded with no underestimation greater than 5%.
