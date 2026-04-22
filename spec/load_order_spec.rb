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
end
