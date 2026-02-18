# Token Estimation Benchmark

Benchmarking the heuristic `(string.length / 3.5).ceil` against tiktoken tokenizers used by OpenAI models.

## Methodology

- **Corpus**: 19 Ruby source files from `lib/codebase_index/` (1.4 KB to 33.4 KB), including extractors, retrieval pipeline, MCP servers, and utility modules
- **Reference tokenizer**: tiktoken_ruby 0.0.15.1 with cl100k_base (GPT-4) and o200k_base (GPT-4o)
- **Heuristic under test**: `(content.length / 3.5).ceil` — the current divisor used across the gem
- **Content analysis**: Additional breakdown of code-only vs. comment/YARD lines across 20 files

## Results

### Per-File Results (cl100k_base, sorted by file size)

| File | Chars | Actual Tokens | Heuristic | Error % | Chars/Token |
|------|------:|-------------:|----------:|--------:|------------:|
| model_name_cache.rb | 1,419 | 360 | 406 | +12.8% | 3.94 |
| ast_source_extraction.rb | 1,462 | 330 | 418 | +26.7% | 4.43 |
| circuit_breaker.rb | 3,191 | 760 | 912 | +20.0% | 4.20 |
| text_preparer.rb | 3,788 | 900 | 1,083 | +20.3% | 4.21 |
| query_classifier.rb | 4,586 | 1,153 | 1,311 | +13.7% | 3.98 |
| extracted_unit.rb | 4,963 | 1,151 | 1,418 | +23.2% | 4.31 |
| retriever.rb | 6,424 | 1,419 | 1,836 | +29.4% | 4.53 |
| dependency_graph.rb | 6,767 | 1,662 | 1,934 | +16.4% | 4.07 |
| semantic_chunker.rb | 8,891 | 2,103 | 2,541 | +20.8% | 4.23 |
| concern_extractor.rb | 9,187 | 2,105 | 2,625 | +24.7% | 4.36 |
| context_assembler.rb | 9,196 | 2,009 | 2,628 | +30.8% | 4.58 |
| job_extractor.rb | 10,968 | 2,586 | 3,134 | +21.2% | 4.24 |
| search_executor.rb | 12,254 | 2,597 | 3,502 | +34.8% | 4.72 |
| graph_analyzer.rb | 12,677 | 2,958 | 3,622 | +22.4% | 4.29 |
| controller_extractor.rb | 16,457 | 3,559 | 4,702 | +32.1% | 4.62 |
| extractor.rb | 23,235 | 5,348 | 6,639 | +24.1% | 4.34 |
| console/server.rb | 27,865 | 5,582 | 7,962 | +42.6% | 4.99 |
| graphql_extractor.rb | 32,469 | 7,344 | 9,277 | +26.3% | 4.42 |
| mcp/server.rb | 33,430 | 6,173 | 9,552 | +54.7% | 5.42 |

### Statistical Summary

| Metric | cl100k_base (GPT-4) | o200k_base (GPT-4o) |
|--------|--------------------:|--------------------:|
| Mean signed error | +26.2% | +27.1% |
| Mean absolute error | 26.2% | 27.1% |
| Max absolute error | 54.7% | 54.6% |
| Min absolute error | 12.8% | 12.2% |
| Std dev | 9.8% | 9.9% |
| Mean chars/token | 4.41 | 4.45 |
| Range chars/token | 3.94 - 5.42 | 3.92 - 5.41 |

### Content Type Analysis (code lines vs. comments/YARD)

| Content Type | Mean Chars/Token | Range |
|-------------|----------------:|------:|
| Code lines only | 4.38 | 3.61 - 5.45 |
| Comment/YARD lines | 4.27 | 3.91 - 4.90 |

Both content types are above 3.5 chars/token. The assumption in the CLAUDE.md that "Ruby code averages ~3.2-3.5 chars/token" is not supported by this corpus.

### Alternative Divisor Comparison

| Divisor | Mean Abs Error (cl100k) | Max Abs Error |
|--------:|------------------------:|--------------:|
| 3.0 | 47.2% | 80.5% |
| 3.2 | 38.0% | 69.2% |
| 3.5 (current) | **26.2%** | **54.7%** |
| 3.8 | 16.2% | 42.5% |
| 4.0 | **10.6%** | **35.4%** |

## Key Findings

1. **The heuristic always overestimates** (positive error across all 19 files). It never underestimates. This makes it conservative (safe for token-limit enforcement), but wasteful.

2. **Mean overestimation is 26.2%** (cl100k) — the heuristic thinks files have ~26% more tokens than they actually do. This exceeds the 10% target from the backlog item.

3. **Large files with repetitive structures are worst.** `mcp/server.rb` (54.7% error) and `console/server.rb` (42.6% error) contain long sequences of similar tool registration blocks. Tokenizers handle repetitive patterns efficiently; the heuristic does not.

4. **cl100k and o200k produce nearly identical results** on Ruby source — no meaningful difference between GPT-4 and GPT-4o tokenizers for this corpus.

5. **A divisor of 4.0 reduces mean error to 10.6%** while still always overestimating. This is the best simple improvement without adding a dependency.

## Practical Impact

The overestimation affects these gem components:

| Component | Effect of 26% Overestimation |
|-----------|------------------------------|
| `ExtractedUnit#estimated_tokens` | Chunks are created ~20% smaller than necessary |
| `TextPreparer#enforce_token_limit` | Embedding input truncated ~20% earlier than needed |
| `ContextAssembler` | Token budget consumed ~20% faster, fewer results returned |
| `CostModel::Estimator` | Cost estimates ~26% higher than actual |
| `SemanticChunker` | More chunks per unit, more embedding API calls |

## Recommendation

**Change the divisor from 3.5 to 4.0.** Rationale:

- Reduces mean error from 26.2% to 10.6% (within the 15% budget for a heuristic)
- Still always overestimates — maintains the conservative safety property
- Zero new dependencies
- Single constant change across 6 files (search for `/ 3.5` and `* 3.5`)
- The original 3.5 figure appears to have been based on minimal-comment pure-code snippets; real Ruby source with YARD docs averages 4.41 chars/token

**Do NOT add tiktoken_ruby as a runtime dependency.** The 10.6% mean error with divisor 4.0 is acceptable for the gem's use cases (chunking decisions, budget estimates, truncation). Adding a native extension dependency for marginal accuracy gains is not worth the complexity.

## Locations Using the Heuristic

All instances of the 3.5 divisor in the codebase:

- `lib/codebase_index/extracted_unit.rb:71-72,98,101` — `estimated_tokens`, chunking
- `lib/codebase_index/chunking/chunk.rb:43` — `token_count`
- `lib/codebase_index/embedding/text_preparer.rb:104,107` — `enforce_token_limit`
- `lib/codebase_index/retrieval/context_assembler.rb:216,225` — truncation, `estimate_tokens`
- `lib/codebase_index/formatting/base.rb:36` — `estimate_tokens`

## Reproducing This Benchmark

```bash
gem install tiktoken_ruby  # Not a Gemfile dependency — benchmark only
ruby scripts/token_benchmark.rb  # Outputs JSON to stdout
```

The benchmark spec at `spec/token_estimation_benchmark_spec.rb` validates:
- Self-consistency of the heuristic (monotonically increasing with content length)
- With tiktoken_ruby installed: bounded overestimation, no underestimation > 5%
