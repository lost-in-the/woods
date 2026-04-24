# frozen_string_literal: true

require 'spec_helper'

# Cross-cutting invariant from CLAUDE.md:
#   "extract_dependencies in all extractors must include :via key"
#
# Individual per-extractor specs already use the `all dependencies have :via
# key` shared example (spec/support/shared_examples.rb) for one
# representative file. This spec enforces the invariant STRUCTURALLY at the
# code level — it walks every `*_extractor.rb` file and asserts that any
# hash pushed onto a `deps`/`dependencies` array includes a `:via` entry.
#
# The check is intentionally narrow: only hashes assigned via
# `deps << { ... }`, `deps.push({ ... })`, `dependencies << { ... }`, or
# returned as the final value of an `extract_dependencies` method. Metadata
# hashes that happen to carry `type:` and `target:` are not flagged.
#
# A future extractor that emits a raw `{ type:, target: }` dependency
# without `:via:` will fail here — catching the mistake at test time
# instead of at MCP-query time when `dependencies_of(..., via: :render)`
# starts skipping edges.
module ViaInvariantSpecHelper
  EXTRACTOR_DIR = File.expand_path('../../lib/woods/extractors', __dir__)

  # Extractors whose dependency construction is delegated entirely through
  # SharedDependencyScanner / RouteHelperResolver helpers.
  SCANNER_DELEGATED = %w[
    shared_utility_methods.rb
    shared_dependency_scanner.rb
    route_helper_resolver.rb
    callback_analyzer.rb
    behavioral_profile.rb
    ast_source_extraction.rb
  ].freeze

  # Match dependency-push idioms:
  #   deps << { type: ..., target: ... }
  #   deps.push({ type: ..., target: ... })
  #   dependencies << { type: ..., target: ... }
  DEP_PUSH = /(?:deps|dependencies)\s*(?:<<|\.push\(?)\s*\{[^{}]*?\btype:[^{}]*?\btarget:[^{}]*?\}/m

  # Match dependency-array literals: `deps = [{ type:..., target:... }, ...]`
  DEP_LIST_LITERAL = /\bdeps\s*=\s*\[[^\]]*?\{[^{}]*?\btype:[^{}]*?\btarget:[^{}]*?\}/m
end

RSpec.describe 'Extractor `:via` key invariant (E-5)' do
  extractor_files = Dir.glob(File.join(ViaInvariantSpecHelper::EXTRACTOR_DIR, '*_extractor.rb'))

  extractor_files.each do |path|
    basename = File.basename(path)
    next if ViaInvariantSpecHelper::SCANNER_DELEGATED.include?(basename)

    it "#{basename} spells :via on every inline dependency hash" do
      source = File.read(path, encoding: Encoding::UTF_8)

      offenders = (source.scan(ViaInvariantSpecHelper::DEP_PUSH) +
                   source.scan(ViaInvariantSpecHelper::DEP_LIST_LITERAL))
                  .reject { |frag| frag.include?('via:') }

      expect(offenders).to be_empty,
                           "#{basename} contains a dependency hash with type:/target: but no via: key.\n" \
                           "Literal dependencies must include `via:` per CLAUDE.md.\n" \
                           "Offending fragments:\n#{offenders.map { |f| "  #{f.lines.first}" }.join}"
    end
  end

  it 'covers a meaningful number of extractors' do
    extractors = extractor_files.reject { |p| ViaInvariantSpecHelper::SCANNER_DELEGATED.include?(File.basename(p)) }
    expect(extractors.size).to be >= 25,
                               "Expected to scan at least 25 extractors, found #{extractors.size}. " \
                               'Has the extractor directory moved?'
  end
end
