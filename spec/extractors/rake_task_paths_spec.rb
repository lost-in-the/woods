# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extractors/rake_task_paths'

RSpec.describe Woods::Extractors::RakeTaskPaths do
  describe '.validate!' do
    it 'accepts recursive globs, flat globs and plain file paths' do
      value = ['lib/tasks/**/*.rake', 'ops/*.rake', 'Rakefile']

      expect(described_class.validate!(value)).to eq(value).and be_frozen
    end

    it 'drops a leading ./ from an entry' do
      expect(described_class.validate!(['./Rakefile'])).to eq(['Rakefile'])
    end

    [
      [nil, 'must be an Array'],
      ['lib/tasks/**/*.rake', 'must be an Array'],
      [[:rake], 'rake_task_paths[0]'],
      [[''], 'rake_task_paths[0]'],
      [['/etc/tasks/*.rake'], 'rake_task_paths[0]'],
      [['lib/../../*.rake'], 'rake_task_paths[0]'],
      [['Rakefile', '**/*.rake'], 'rake_task_paths[1]'],
      [['lib/*/tasks/*.rake'], 'rake_task_paths[0]'],
      [['lib/tasks/**/*'], 'rake_task_paths[0]'],
      [['lib/tasks/**/*.{rake,rb}'], 'rake_task_paths[0]'],
      [['lib/tasks/**/task_*.rake'], 'rake_task_paths[0]']
    ].each do |value, message|
      it "rejects #{value.inspect}" do
        expect { described_class.validate!(value) }
          .to raise_error(Woods::ConfigurationError, /#{Regexp.escape(message)}/)
      end
    end
  end

  describe '.rule_attributes' do
    it 'turns each entry into plain rule data' do
      attributes = described_class.rule_attributes(['lib/tasks/**/*.rake', 'ops/*.rake', 'Rakefile'])

      expect(attributes).to eq(
        [
          { dirs: ['lib/tasks'], extensions: %w[.rake .rb] },
          { dirs: ['ops'], extensions: ['.rake'], recursive: false },
          { dirs: ['ops'], extensions: ['.rb'] },
          { dirs: [], exact_paths: ['Rakefile'] }
        ]
      )
    end

    it 'serializes identically on every call' do
      first = JSON.generate(described_class.rule_attributes(described_class::DEFAULT_PATHS))
      second = JSON.generate(described_class.rule_attributes(described_class::DEFAULT_PATHS.dup))

      expect(first).to eq(second)
    end
  end

  describe 'path predicates' do
    let(:paths) { ['lib/tasks/**/*.rake', 'ops/*.rake', 'Rakefile'] }

    it 'matches task files under a root at the configured depth' do
      expect(described_class.task_file?('lib/tasks/a/b/export.rake', paths)).to be(true)
      expect(described_class.task_file?('ops/deploy.rake', paths)).to be(true)
      expect(described_class.task_file?('ops/nested/deploy.rake', paths)).to be(false)
      expect(described_class.task_file?('Rakefile', paths)).to be(true)
      expect(described_class.task_file?('engines/billing/Rakefile', paths)).to be(false)
      expect(described_class.task_file?('lib/tasks_extra/export.rake', paths)).to be(false)
    end

    it 'matches Ruby support files anywhere under a root' do
      expect(described_class.support_file?('ops/lib/container.rb', paths)).to be(true)
      expect(described_class.support_file?('lib/tasks/support/format.rb', paths)).to be(true)
      expect(described_class.support_file?('lib/widget.rb', paths)).to be(false)
      expect(described_class.support_file?('ops/lib/notes.md', paths)).to be(false)
    end

    it 'covers both kinds' do
      expect(described_class.covers?('ops/lib/container.rb', paths)).to be(true)
      expect(described_class.covers?('ops/deploy.rake', paths)).to be(true)
      expect(described_class.covers?('app/models/widget.rb', paths)).to be(false)
    end
  end

  describe 'file discovery' do
    around do |example|
      Dir.mktmpdir do |dir|
        @root = Pathname.new(File.realpath(dir))
        example.run
      end
    end

    def touch(relative)
      path = @root.join(relative)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, '')
    end

    it 'lists task and support files sorted, skipping missing roots' do
      %w[rake/z.rake rake/a/b.rake rake/lib/helper.rb rake/nested.txt Rakefile lib/widget.rb].each { |f| touch(f) }

      expect(described_class.task_files(@root, described_class::DEFAULT_PATHS))
        .to eq(%w[Rakefile rake/a/b.rake rake/z.rake].map { |f| @root.join(f).to_s })
      expect(described_class.support_files(@root, described_class::DEFAULT_PATHS))
        .to eq([@root.join('rake/lib/helper.rb').to_s])
    end
  end
end
