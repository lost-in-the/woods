# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'set'
require 'json'
require 'active_support'
require 'active_support/core_ext/time'
require 'woods/extractor'
require 'woods/skipped_files'

# Every incremental cycle rebuilds the skipped-files report (#721). It used to
# ask Git about each configuration source on its own, so a cycle that changed
# nothing paid one process per untracked or ignored source. The report now
# reads Git once per change to Git's inputs, in a constant number of calls,
# and a cycle over an unchanged tree spawns no git process at all.
RSpec.describe Woods::SkippedFiles, 'Git work for configuration sources' do
  include_context 'extractor setup'

  around do |example|
    original = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    example.run
  ensure
    Woods.configuration = original
  end

  before do
    stub_const('ActiveRecord::Base', double('ActiveRecord::Base', descendants: []))
    Woods::GitSourceFilter.reset_availability!
  end

  after { Woods::GitSourceFilter.reset_availability! }

  def git(*args)
    _out, err, status = Open3.capture3(*Woods::GitCommand.argv(tmp_dir, *args))
    raise err unless status.success?
  end

  def git_spawns
    count = 0
    allow(Open3).to receive(:capture3).and_wrap_original do |original, *args, **options|
      count += 1 if args.first == 'git'
      original.call(*args, **options)
    end
    yield
    count
  end

  def report
    described_class.new(root: tmp_dir).build([])
  end

  def reasons
    report.fetch('files').to_h { |entry| [entry['path'], entry['reason']] }
  end

  let(:untracked) { Array.new(30) { |i| "config/initializers/local_#{i}.rb" } }

  def build_repository
    git('init', '--quiet')
    create_file('config/initializers/tracked.rb', "# tracked\n")
    create_file('config/tracked then ignored é.yml', "key: value\n")
    create_file('config/odd name [1].yml', "key: value\n")
    git('add', '.')
    create_file('.gitignore', "config/tracked then ignored é.yml\nconfig/hidden*.yml\nconfig/ignored dir/\n")
    create_file('config/hidden ünïcode.yml', "key: value\n")
    create_file('config/ignored dir/settings.yml', "key: value\n")
    create_file('config/untracked spaced ü.yml', "key: value\n")
    untracked.each { |path| create_file(path, "# local\n") }
  end

  let(:expected) do
    {
      'config/tracked then ignored é.yml' => 'git_ignored',
      'config/hidden ünïcode.yml' => 'git_ignored',
      'config/ignored dir/settings.yml' => 'git_ignored',
      'config/untracked spaced ü.yml' => 'untracked'
    }.merge(untracked.to_h { |path| [path, 'untracked'] })
  end

  it 'gives every configuration source the reason Git gives it alone' do
    build_repository

    expect(reasons).to eq(expected)
    filter = Woods::GitSourceFilter.new(root: tmp_dir)
    expected.each_key { |path| expect(filter.skip_reason(path)).to eq(expected.fetch(path)) }
    expect(filter.skip_reason('config/initializers/tracked.rb')).to be_nil
    expect(filter.skip_reason('config/odd name [1].yml')).to be_nil
  end

  # The first report also asks once where Git keeps its files and which
  # global excludes file it reads. After that, a changed index costs two
  # listings of it and one check-ignore call over every untracked source.
  it 'answers many untracked sources with a constant number of git processes' do
    build_repository
    Woods::GitSourceFilter.new(root: tmp_dir).available?

    expect(git_spawns { report }).to be <= 5
    git('add', 'config/initializers/tracked.rb', 'config/odd name [1].yml', '--chmod=+x')
    expect(git_spawns { report }).to eq(3)
  end

  it 'spawns no git process for a report over an unchanged tree' do
    build_repository
    first = report

    second = nil
    expect(git_spawns { second = report }).to eq(0)
    expect(JSON.generate(second)).to eq(JSON.generate(first))
  end

  it 'follows the index when a source is added' do
    build_repository
    report
    git('add', 'config/untracked spaced ü.yml')

    expect(reasons).to eq(expected.except('config/untracked spaced ü.yml'))
  end

  it 'follows an edited ignore file in a source directory' do
    build_repository
    report
    create_file('config/initializers/.gitignore', "local_1*.rb\n")

    ignored = untracked.select { |path| File.basename(path).start_with?('local_1') }
    expect(reasons).to eq(expected.merge(ignored.to_h { |path| [path, 'git_ignored'] }))
  end

  it 'follows the repository exclude file and a configured global excludes file' do
    build_repository
    excludes = File.join(tmp_dir, '..', "#{File.basename(tmp_dir)}-excludes")
    File.write(excludes, '')
    git('config', 'core.excludesFile', excludes)
    report

    File.write(excludes, "local_2*.rb\n")
    File.write(File.join(tmp_dir, '.git/info/exclude'), "local_3*.rb\n")

    ignored = untracked.select { |path| File.basename(path).start_with?('local_2', 'local_3') }
    expect(reasons).to eq(expected.merge(ignored.to_h { |path| [path, 'git_ignored'] }))
  ensure
    FileUtils.rm_f(excludes) if excludes
  end

  it 'lists no Git reason and spawns no git process without a Git work tree' do
    create_file('config/initializers/local.rb', "# local\n")

    files = nil
    expect(git_spawns { files = report.fetch('files') }).to eq(0)
    expect(files).to be_empty
  end

  it 'lists no Git reason when the Git executable is unavailable' do
    build_repository
    allow(Open3).to receive(:capture3).and_call_original
    allow(Open3).to receive(:capture3).with('git', '--version').and_raise(Errno::ENOENT)

    expect(report.fetch('files')).to be_empty
  end

  describe Woods::GitSourceFilter do
    it 'answers a batch, including a path outside the repository, as path by path' do
      build_repository
      paths = [*expected.keys, 'config/initializers/tracked.rb', File.join(tmp_dir, 'config/hidden ünïcode.yml'),
               '/elsewhere/config/settings.yml']
      alone = paths.to_h { |path| [path, described_class.new(root: tmp_dir).skip_reason(path)] }
      described_class.reset_availability!

      batch = described_class.new(root: tmp_dir).skip_reasons(paths)

      expect(paths.to_h { |path| [path, batch.fetch(path.delete_prefix("#{tmp_dir}/"))] }).to eq(alone)
    end
  end

  describe Woods::Extractor do
    it 'does no git work for the report on a no-op incremental cycle' do
      build_repository
      extractor = described_class.new(output_dir: File.join(tmp_dir, 'index'))
      allow(extractor).to receive(:payload_dir).and_return(Pathname.new(tmp_dir))
      first, = extractor.send(:skipped_files_report)

      second = nil
      expect(git_spawns { second, = extractor.send(:skipped_files_report) }).to eq(0)
      expect(second).to eq(first)
    end
  end
end
