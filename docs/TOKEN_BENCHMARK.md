# Token Estimation Benchmark

> **Historical sizing evidence, not an input-limit guarantee.**
> `Woods::TokenUtils.chars_per_token_for(provider)` supplies character estimates
> for retrieval assembly and initial sizing. Unreleased builds after 2.0.0 use
> a conservative UTF-8 byte bound for known OpenAI embedding models and honest
> estimates for Ollama/custom models. Prefixes count toward admission; oversized
> inputs are split without dropping source. The optional tokenizer gem no longer
> downloads or implicitly selects BERT. See [Embedding Models](EMBEDDING_MODELS.md).

This is a historical record of the benchmark that picked 4.0 over the
original 3.5 divisor. It is cited from five places in `lib/` as the evidence
for that choice, keep the numbers below intact if you edit this doc.

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

Mean chars/token across the corpus was **4.41** (range 3.94–5.42). These
aggregate results favor the 4.0 divisor for this sample; they do not establish
an upper bound on token counts. The recorded range includes values below 4.0,
so the heuristic can underestimate. Code lines and comment/YARD lines had
similar ratios (4.38 vs. 4.27 chars/token) in this sample.

The character estimate covers only the text passed to the counter. It does not
bound the serialized MCP response: text rendering, structured output, provenance,
and JSON framing can add bytes and tokens beyond that input.

## What shipped

**The divisor changed from 3.5 to 4.0.** It roughly halves the mean
error (26.2% → 10.6%) at zero new runtime dependencies. It remains an estimate,
not a guarantee that arbitrary input fits a model's token limit. The
constant lives in one place now (`Woods::TokenUtils::CHARS_PER_TOKEN_BY_PROVIDER`),
not scattered across call sites, see `lib/woods/token_utils.rb` for the
current definition and `docs/EMBEDDING_MODELS.md` for the Ollama-side ratio.

**tiktoken_ruby was deliberately not added as a runtime dependency.** A 10.6%
mean error is acceptable for chunking decisions, budget estimates, and
truncation; a native-extension dependency for marginal accuracy gains wasn't
worth it. An explicitly injected local tokenizer must match the target model. A conservative
upper bound can also establish admission for a known encoding; a character
average cannot.

## Reproducing this benchmark

```bash
gem install tiktoken_ruby  # not a Gemfile dependency, benchmark only
```

`spec/token_estimation_benchmark_spec.rb` keeps this honest going forward: it
checks the heuristic is self-consistent (monotonically increasing with
content length) and, when tiktoken_ruby is installed, that overestimation
stays bounded with no underestimation greater than 5%.
