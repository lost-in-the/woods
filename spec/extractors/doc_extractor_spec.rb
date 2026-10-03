# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/doc_extractor'

RSpec.describe Woods::Extractors::DocExtractor do
  include_context 'extractor setup'

  around do |example|
    original = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    example.run
  ensure
    Woods.configuration = original
  end

  def unit_for(relative, content)
    described_class.new.extract_doc_file(create_file(relative, content))
  end

  describe '#extract_all' do
    it 'returns nothing when the app has no documentation' do
      expect(described_class.new.extract_all).to eq([])
    end

    it 'indexes the default roots, sorted by path' do
      %w[README.md CLAUDE.md AGENTS.md docs/setup.md docs/guides/ledger.md doc/notes.md
         .claude/rules/style.md .claude/skills/deploy/SKILL.md .github/pull_request_template.md].each do |path|
        create_file(path, "# #{path}\n")
      end

      units = described_class.new.extract_all

      expect(units.map(&:identifier)).to eq(%w[.claude/rules/style.md .claude/skills/deploy/SKILL.md
                                               .github/pull_request_template.md AGENTS.md CLAUDE.md README.md
                                               doc/notes.md docs/guides/ledger.md docs/setup.md])
      expect(units.map(&:type).uniq).to eq([:doc])
    end

    it 'excludes changelogs, vendored trees, generated API docs and files outside the roots' do
      %w[docs/CHANGELOG.md docs/node_modules/pkg/README.md docs/vendor/lib/README.md doc/api/index.md
         docs/api/widget.md NOTES.md app/models/README.md .claude/worktrees/a/docs/x.md docs/.drafts/x.md
         docs/keep.md docs/notes.txt].each { |path| create_file(path, "# #{path}\n") }

      expect(described_class.new.extract_all.map(&:identifier)).to eq(['docs/keep.md'])
    end

    it 'follows configured paths and excludes' do
      create_file('handbook/ledger.md', '# Ledger')
      create_file('handbook/drafts/wip.md', '# WIP')
      create_file('README.md', '# Readme')
      Woods.configuration.documentation_paths = ['handbook/**/*.md']
      Woods.configuration.documentation_exclude = ['handbook/drafts/**/*']

      expect(described_class.new.extract_all.map(&:identifier)).to eq(['handbook/ledger.md'])
    end

    it 'indexes nothing when the paths are empty' do
      create_file('README.md', '# Readme')
      Woods.configuration.documentation_paths = []

      expect(described_class.new.extract_all).to eq([])
    end
  end

  describe '#extract_doc_file' do
    let(:source) do
      <<~MARKDOWN
        ---
        title: Widget imports
        owner: platform
        api_token: plainvalue
        ---
        # Importing widgets

        `Widget::Importer` reads `app/models/widget.rb`. Run `rake widgets:sync`.
        See [setup](setup.md#install), [the model](../app/models/widget.rb) and
        [the site](https://example.test/docs).

        ## Endpoints

        ```
        GET /widgets
        Widget::Importer.call
        ```
      MARKDOWN
    end
    let(:unit) { unit_for('docs/widgets.md', source) }

    it 'identifies the unit by its root-relative path' do
      expect(unit.identifier).to eq('docs/widgets.md')
      expect(unit.file_path).to eq(File.join(tmp_dir, 'docs/widgets.md'))
      expect(unit.namespace).to be_nil
      expect(unit.dependencies).to eq([])
    end

    it 'records title, outline, front matter and counts' do
      expect(unit.metadata).to include(
        title: 'Importing widgets',
        headings: [{ level: 1, text: 'Importing widgets', line: 6 }, { level: 2, text: 'Endpoints', line: 12 }],
        front_matter: { 'title' => 'Widget imports', 'owner' => 'platform', 'api_token' => '[REDACTED]' },
        line_count: 17
      )
      expect(unit.metadata[:word_count]).to be > 10
    end

    it 'falls back to the file name for the title' do
      expect(unit_for('docs/plain.md', "no heading\n").metadata[:title]).to eq('plain')
    end

    it 'records links with relative targets resolved to repository paths' do
      expect(unit.metadata[:links]).to eq([
                                            { target: '../app/models/widget.rb', kind: 'relative',
                                              path: 'app/models/widget.rb', resolved: false },
                                            { target: 'https://example.test/docs', kind: 'external', path: nil,
                                              resolved: false },
                                            { target: 'setup.md#install', kind: 'relative', path: 'docs/setup.md',
                                              resolved: false }
                                          ])
    end

    it 'classifies anchors, root-relative links and links that leave the repository' do
      links = unit_for('docs/a/b.md', "[a](#top) [b](/README.md) [c](../../../etc/x.md) [d](my%20doc.md?raw=1)\n")
              .metadata[:links].to_h { |link| [link[:target], link.values_at(:kind, :path)] }

      expect(links).to eq('#top' => ['anchor', nil], '/README.md' => ['relative', 'README.md'],
                          '../../../etc/x.md' => ['relative', nil],
                          'my%20doc.md?raw=1' => ['relative', 'docs/a/my doc.md'])
    end

    it 'records unresolved mention candidates once each, sorted, with their first line' do
      expect(unit.metadata[:mentions]).to eq([
                                               { kind: 'constant', text: 'Widget::Importer', line: 8, resolved: false },
                                               { kind: 'path', text: 'app/models/widget.rb', line: 8,
                                                 resolved: false },
                                               { kind: 'rake_task', text: 'widgets:sync', line: 8, resolved: false },
                                               { kind: 'route', text: 'GET /widgets', line: 15, resolved: false }
                                             ])
      expect(unit.metadata[:mentions_truncated]).to be(false)
    end

    it 'caps the mention list and says so' do
      body = (1..(described_class::MAX_MENTIONS + 20)).map { |n| "`Widget#{n}`" }.join("\n")
      metadata = unit_for('docs/many.md', body).metadata

      expect(metadata[:mentions].size).to eq(described_class::MAX_MENTIONS)
      expect(metadata[:mentions_truncated]).to be(true)
    end

    it 'publishes redacted source and never a redacted value as a mention' do
      key = "AKIA#{'ABCD1234' * 2}"
      redacted = unit_for('docs/secrets.md', "# Keys\n\nUse `#{key}` with `Ledger`.\n")

      expect(redacted.source_code).to eq("# Keys\n\nUse `[REDACTED]` with `Ledger`.\n")
      expect(redacted.metadata[:redactions]).to eq('aws_access_key_id' => 1)
      expect(redacted.metadata[:mentions].map { |mention| mention[:text] }).to eq(['Ledger'])
      expect(JSON.generate(redacted.to_h)).not_to include(key)
    end

    it 'redacts credential-named front matter in the source too' do
      expect(unit.source_code).to include('api_token: [REDACTED]')
      expect(unit.source_code).not_to include('plainvalue')
    end

    it 'chunks by heading section' do
      expect(unit.chunks.map { |chunk| chunk[:metadata][:heading] }).to eq([nil, 'Importing widgets', 'Endpoints'])
      expect(unit.chunks.map { |chunk| chunk[:identifier] }.uniq.size).to eq(3)
    end

    it 'leaves a single-section document whole' do
      expect(unit_for('docs/one.md', "# Only\n\ntext\n").chunks).to eq([])
    end

    it 'returns nil for a path outside the configured roots and for an excluded path' do
      expect(unit_for('notes/x.md', '# x')).to be_nil
      expect(unit_for('docs/CHANGELOG.md', '# x')).to be_nil
    end

    it 'skips a document over the size cap' do
      stub_const("#{described_class}::MAX_DOC_BYTES", 64)

      expect(unit_for('docs/big.md', "# Big\n#{'word ' * 40}")).to be_nil
    end

    it 'refuses a symlink that leaves the repository or lands outside the documentation roots' do
      outside = Dir.mktmpdir
      File.write(File.join(outside, 'leak.md'), '# Leaked')
      create_file('config/master.key', 'notakey')
      FileUtils.mkdir_p(File.join(tmp_dir, 'docs'))
      File.symlink(File.join(outside, 'leak.md'), File.join(tmp_dir, 'docs/outside.md'))
      File.symlink(File.join(tmp_dir, 'config/master.key'), File.join(tmp_dir, 'docs/key.md'))
      create_file('docs/real.md', '# Real')
      File.symlink(File.join(tmp_dir, 'docs/real.md'), File.join(tmp_dir, 'docs/alias.md'))

      expect(described_class.new.extract_all.map(&:identifier)).to eq(%w[docs/alias.md docs/real.md])
      expect(described_class.new.extract_doc_file(File.join(tmp_dir, 'docs/outside.md'))).to be_nil
      expect(described_class.new.extract_doc_file(File.join(tmp_dir, 'docs/key.md'))).to be_nil
    ensure
      FileUtils.rm_rf(outside) if outside
    end

    it 'reads invalid UTF-8 without raising' do
      path = create_file('docs/bytes.md', "# Bytes\n")
      File.binwrite(path, "# Bytes \xFF\n\n`Widget`\n")

      expect(described_class.new.extract_doc_file(path).metadata[:mentions].map { |m| m[:text] }).to eq(['Widget'])
    end

    it 'produces identical JSON on a repeat run' do
      path = create_file('docs/widgets.md', source)
      runs = Array.new(2) { JSON.generate(described_class.new.extract_doc_file(path).to_h.except(:extracted_at)) }

      expect(runs.first).to eq(runs.last)
    end
  end

  describe '.doc_path?' do
    it 'matches the default roots and nothing hidden or ignored' do
      expect(%w[README.md docs/a/b.md .github/ISSUE_TEMPLATE/bug.md .claude/skills/x/SKILL.md]
        .all? { |path| described_class.doc_path?(path) }).to be(true)
      expect(%w[lib/README.md docs/a.txt tmp/docs/a.md CHANGELOG.md docs/.git/a.md .claude/settings.md]
        .none? { |path| described_class.doc_path?(path) }).to be(true)
    end
  end

  describe 'configuration' do
    it 'refuses malformed globs and keeps the previous value' do
      config = Woods.configuration

      expect { config.documentation_paths = 'docs' }.to raise_error(Woods::ConfigurationError, /must be an Array/)
      expect { config.documentation_paths = ['/abs/*.md'] }.to raise_error(Woods::ConfigurationError, /relative glob/)
      expect { config.documentation_exclude = ['../x'] }.to raise_error(Woods::ConfigurationError, /relative glob/)
      expect { config.documentation_paths = ['.cursor/rules/*.md'] }
        .to raise_error(Woods::ConfigurationError, /hidden directory/)
      expect(config.documentation_paths).to eq(Woods::Configuration::DEFAULT_DOCUMENTATION_PATHS)
    end

    it 'validates retrieve_documentation as a boolean' do
      expect { Woods.configuration.retrieve_documentation = 'no' }.to raise_error(Woods::ConfigurationError)
      expect(Woods.configuration.retrieve_documentation).to be(true)
    end
  end
end
