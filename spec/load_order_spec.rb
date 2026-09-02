# frozen_string_literal: true

require 'spec_helper'
require 'open3'

# Guards against "require X in isolation and a constant blows up" bugs.
#
# spec_helper eagerly requires woods/extracted_unit, so in-process tests can
# never detect a missing sibling require. Each case shells out to a fresh
# Ruby process to exercise the exact load order a user would hit by running
# `bin/rails woods:embed` (or any other narrow entry point).
# Files that reference Woods::ExtractedUnit directly. When required alone,
# ExtractedUnit must already be defined — otherwise the caller gets
# NameError the moment the referencing method runs.
STANDALONE_EXTRACTED_UNIT_LOADERS = %w[
  woods/embedding/indexer
  woods/extractors/rails_source_extractor
].freeze

# Files that must load cleanly on their own — the repo's standalone-require
# shim convention (`class Error < StandardError; end unless defined?`, plus
# explicit requires for every constant referenced at load time). Any narrow
# entry point — a host script, an exe, a spec that bypasses lib/woods.rb —
# hits exactly this order, and a gap surfaces as a NameError at require time
# rather than anywhere near its cause (STO-5).
STANDALONE_LOADABLE = %w[
  woods/cache/cache_middleware
  woods/cache/cache_store
  woods/embedding/indexer
  woods/embedding/provider
  woods/extractors/rails_source_extractor
  woods/resilience/circuit_breaker
  woods/storage/metadata_store
  woods/storage/pgvector
  woods/storage/qdrant
  woods/storage/vector_store
].freeze

RSpec.describe 'Load order' do
  STANDALONE_EXTRACTED_UNIT_LOADERS.each do |lib|
    it "resolves Woods::ExtractedUnit after `require '#{lib}'` alone" do
      stdout, status = Open3.capture2e(
        'ruby', '-Ilib', "-r#{lib}",
        '-e', 'exit(defined?(Woods::ExtractedUnit) ? 0 : 1)'
      )
      expect(status).to be_success, "ExtractedUnit undefined after requiring #{lib} in isolation:\n#{stdout}"
    end
  end

  describe 'require in isolation' do
    STANDALONE_LOADABLE.each do |lib|
      it "loads `#{lib}` in a fresh process without other woods files" do
        stdout, status = Open3.capture2e('ruby', '-Ilib', '-e', "require '#{lib}'")

        expect(status).to be_success, "requiring #{lib} in isolation failed:\n#{stdout}"
      end
    end
  end
end
