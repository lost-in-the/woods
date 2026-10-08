# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'rbconfig'

# Adversarial documents: 50k repeats and 10k near-matches per shape. The
# extractor adds no regular expression of its own (the fixture also runs under
# Regexp.timeout = 1), so the bound guards its own passes over what the
# graphql gem's parser returns.
RSpec.describe 'GraphQL operation extraction complexity' do
  before(:all) do
    script = File.expand_path('../fixtures/graphql_operations/extract.rb', __dir__)
    output, error, status = Open3.capture3({ 'MODE' => 'adversarial' }, RbConfig.ruby, '-Ilib', script)
    raise "fixture failed: #{error}\n#{output}" unless status.success?

    @result = JSON.parse(output.lines.last.force_encoding('UTF-8'))
  end

  let(:result) { @result }
  let(:counts) { result.fetch('units').to_h { |unit| [unit['identifier'], unit['counts']] } }

  it 'extracts every oversized document within the time bound' do
    expect(result.fetch('elapsed')).to be < 5
  end

  it 'collapses 50k repeated selections into their distinct fields' do
    expect(counts.fetch('gql:Flat')).to include('field_selections' => 2, 'unknown_fields' => 0)
  end

  it 'records 10k near-miss fields and spreads as drift' do
    expect(counts.fetch('gql:Unknown')).to include('unknown_fields' => 10_000)
    expect(counts.fetch('gql:Spreads')).to include('unknown_fragments' => 1)
  end

  it 'keeps 10k definitions in one document distinct' do
    expect(counts.keys.grep(/\Agql:F\d+\z/).size).to eq(10_000)
  end

  it 'drops 50k trailing comment lines from a definition without rescanning them' do
    expect(counts).to include('gql:Trailing', 'gql:Tail', 'gql:Commented')
  end

  it 'skips a document nested past the parser limit instead of failing the run' do
    expect(counts.keys).not_to include('gql:Nested')
    expect(result.fetch('log')).to include('app/javascript/adv/nested.graphql')
  end
end
