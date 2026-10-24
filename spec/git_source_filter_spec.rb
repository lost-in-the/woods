# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'woods/git_source_filter'

# The filter answers for every configuration path a source check or a
# dispatch classifies. It used to spawn one or two git processes per path,
# which on its own used up a quick freshness check's time budget; it now
# reads the index and the ignore rules once per filter.
RSpec.describe Woods::GitSourceFilter do
  around do |example|
    Dir.mktmpdir('woods-git-filter') do |dir|
      @repo = dir
      example.run
    end
  end

  def git(*args, dir: @repo)
    _out, err, status = Open3.capture3('git', '-C', dir, *args)
    raise err unless status.success?
  end

  def write(path, root: @repo)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, "# #{path}\n")
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

  let(:tracked) { Array.new(40) { |i| "config/initializers/setting_#{i}.rb" } + ['config/odd name [1].yml'] }

  def build_repository
    git('init', '--quiet')
    tracked.each { |path| write(path) }
    write('config/tracked_then_ignored.yml')
    git('add', '.')
    File.write(File.join(@repo, '.gitignore'), "config/tracked_then_ignored.yml\nconfig/local.yml\n")
    write('config/local.yml')
    write('config/untracked.yml')
  end

  it 'gives the same reasons as one git call per path' do
    build_repository
    filter = described_class.new(root: @repo)

    expect(tracked.map { |path| filter.skip_reason(path) }.uniq).to eq([nil])
    expect(filter.skip_reason('config/tracked_then_ignored.yml')).to eq('git_ignored')
    expect(filter.skip_reason('config/local.yml')).to eq('git_ignored')
    expect(filter.skip_reason('config/untracked.yml')).to eq('untracked')
    expect(filter.skip_reason(File.join(@repo, 'config/untracked.yml'))).to eq('untracked')
  end

  it 'answers many tracked paths with a fixed number of git processes' do
    build_repository
    filter = described_class.new(root: @repo)

    spawns = git_spawns { tracked.each { |path| filter.skip_reason(path) } }
    expect(spawns).to be <= 4
  end

  it 'probes a root it has already found usable only once per process' do
    build_repository
    described_class.new(root: @repo).skip_reason(tracked.first)

    spawns = git_spawns { described_class.new(root: @repo).skip_reason(tracked.first) }
    expect(spawns).to eq(2)
  end
end
