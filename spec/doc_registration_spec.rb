# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'active_support/core_ext/string/inflections'
require 'woods'
require 'woods/extractor'
require 'woods/input_rules'
require 'woods/source_inputs/scopes'
require 'woods/watch/tree_scan'
require 'woods/mcp/index_reader'
require 'woods/hooks/rule_projection'

RSpec.describe 'Documentation unit registration' do
  around do |example|
    original = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods::PathDispatcher.reset!
    example.run
  ensure
    Woods.configuration = original
    Woods::PathDispatcher.reset!
  end

  let(:documents) do
    %w[README.md CLAUDE.md AGENTS.md docs/setup.md docs/guides/ledger.md doc/notes.md
       .claude/rules/style.md .claude/skills/deploy/SKILL.md .github/pull_request_template.md]
  end
  let(:other_markdown) { %w[CHANGELOG.md NOTES.md app/README.md docs/vendor/a.md .claude/worktrees/a/README.md] }

  describe Woods::Extractor do
    it 'registers the docs extractor, its type and its per-file method' do
      expect(described_class::EXTRACTORS[:docs]).to eq(Woods::Extractors::DocExtractor)
      expect(described_class::TYPE_TO_EXTRACTOR_KEY[:doc]).to eq(:docs)
      expect(described_class::FILE_BASED[:doc]).to eq(:extract_doc_file)
      expect(described_class::WHOLE_APP_EXTRACTORS).not_to have_key(:docs)
    end
  end

  describe Woods::PathDispatcher do
    let(:dispatcher) { described_class.new }

    it 'dispatches documentation to the docs extractor and nothing else' do
      documents.each do |path|
        rules = dispatcher.file_rules_for(path)
        expect(rules.map { |rule| [rule.extractor_key, rule.method_name] }).to eq([%i[docs extract_doc_file]]), path
        expect(dispatcher.relevant?(path)).to be(true), path
      end
    end

    it 'leaves other Markdown alone' do
      other_markdown.each { |path| expect(dispatcher.relevant?(path)).to be(false), path }
    end

    it 'follows the configured paths at call time' do
      expect(dispatcher.relevant?('handbook/ledger.md')).to be(false)
      Woods.configuration.documentation_paths = ['handbook/**/*.md']

      expect(dispatcher.relevant?('handbook/ledger.md')).to be(true)
      expect(dispatcher.relevant?('README.md')).to be(false)
    end

    it 'keeps the rule plain data, identical whatever the configuration' do
      rule = described_class.file_rules.find { |candidate| candidate.extractor_key == :docs }
      before = JSON.generate(rule.to_h)
      Woods.configuration.documentation_paths = ['handbook/**/*.md']
      described_class.reset!
      after = JSON.generate(described_class.file_rules.find { |candidate| candidate.extractor_key == :docs }.to_h)

      expect(after).to eq(before)
      expect(rule.to_h.values.flatten).to all(satisfy { |value| !value.is_a?(Proc) })
    end

    it 'describes the default roots for the generated hook predicate' do
      rule = described_class.file_rules.find { |candidate| candidate.extractor_key == :docs }
      projected = Woods::Configuration::DEFAULT_DOCUMENTATION_PATHS.map do |glob|
        glob.include?('*') ? glob.delete_suffix('/**/*.md') : glob
      end

      expect(rule.exact_paths + rule.dirs).to match_array(projected)
      expect(rule.exact_paths).to eq(Woods::Extractors::DocExtractor::DEFAULT_ROOT_FILES)
      expect(rule.extensions).to eq(%w[.md])
      expect(Woods::Hooks::RuleProjection.new.render).to include('README.md', '.claude/rules/')
    end
  end

  describe Woods::ReloadPolicy do
    let(:policy) { described_class.new }

    it 'classifies documentation as bytes to re-extract' do
      documents.each { |path| expect(policy.classify(path)).to eq(:reextract), path }
    end

    it 'ignores other Markdown and non-Markdown files under a documentation root' do
      (other_markdown + %w[docs/diagram.png .github/workflows/ci.yml]).each do |path|
        expect(policy.classify(path)).to eq(:ignore), path
      end
    end

    it 'follows configured paths when the extractor is loaded' do
      Woods.configuration.documentation_paths = ['handbook/**/*.md']

      expect(policy.classify('handbook/ledger.md')).to eq(:reextract)
    end

    it 'falls back to the default roots in a process without a configuration' do
      Woods.configuration = nil

      expect(policy.classify('docs/setup.md')).to eq(:reextract)
      expect(policy.classify('README.md')).to eq(:reextract)
      expect(policy.classify('handbook/ledger.md')).to eq(:ignore)
      expect(policy.classify('docs/diagram.png')).to eq(:ignore)
    end
  end

  it 'selects incremental work for a documentation edit and a full run for nothing' do
    rules = Woods::InputRules.new

    expect(documents.map { |path| rules.action(path) }.uniq).to eq([:incremental])
    expect(rules.action('NOTES.md')).to eq(:ignore)
  end

  it 'captures documentation under the docs file scope' do
    scopes = Woods::SourceInputs::Scopes.new

    expect(documents.map { |path| scopes.for_path(path) }.uniq).to eq([['file:docs']])
    expect(scopes.for_path('NOTES.md')).to eq([])
  end

  describe Woods::Watch::TreeScan do
    it 'walks the documentation dot directories and nothing else hidden' do
      visible = %w[.claude .claude/rules .claude/rules/style.md .claude/skills/deploy/SKILL.md .github
                   .github/ISSUE_TEMPLATE/bug.md]
      hidden = %w[.claude/worktrees .claude/worktrees/a/README.md .claude/settings.json .claude/rules/.draft.md
                  .git .git/config .cursor/rules/a.md docs/.hidden/a.md .hidden_thing]

      expect(visible.reject { |path| described_class.hidden?(path) }).to eq(visible)
      expect(hidden.select { |path| described_class.hidden?(path) }).to eq(hidden)
    end
  end

  it 'serves doc units from the docs directory' do
    expect(Woods::MCP::IndexReader::TYPE_DIRS).to include('docs')
    expect(Woods::MCP::IndexReader::DIR_TO_TYPE['docs']).to eq('doc')
    expect(Woods::MCP::IndexReader::UNIT_TYPE_TO_DIR['doc']).to eq('docs')
  end

  it 'chunks a doc unit by section when nothing pre-chunked it' do
    unit = Woods::ExtractedUnit.new(type: :doc, identifier: 'docs/ledger.md', file_path: '/app/docs/ledger.md')
    unit.source_code = "# Ledger\n\n#{'Posting entries. ' * 60}\n\n## Closing\n\n#{'Closing the books. ' * 60}\n"

    chunks = Woods::Chunking::SemanticChunker.new.chunk(unit)

    expect(chunks.map { |chunk| chunk.chunk_type.to_s }).to eq(%w[section_0 section_1])
  end
end
