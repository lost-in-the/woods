# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'woods/git_source_filter'
require 'woods/git_command'

RSpec.describe Woods::GitSourceFilter do
  let(:root) { Dir.mktmpdir('woods_git_filter') }
  let(:filter) { described_class.new(root: root) }
  let(:paths) do
    ['config/tracked.rb', 'config/ignored_tracked.rb', 'config/local.yml', 'config/untracked.rb', 'config/odd name.rb']
  end

  after { FileUtils.rm_rf(root) }

  def git(*args)
    _out, err, status = Open3.capture3(*Woods::GitCommand.argv(root, *args))
    raise err unless status.success?
  end

  before do
    git('init', '--quiet')
    paths.each do |path|
      FileUtils.mkdir_p(File.join(root, File.dirname(path)))
      File.write(File.join(root, path), "# source\n")
    end
    git('add', 'config/tracked.rb', 'config/ignored_tracked.rb', 'config/odd name.rb')
    File.write(File.join(root, '.gitignore'), "config/ignored_tracked.rb\nconfig/local.yml\n")
  end

  def git_processes
    count = 0
    allow(Open3).to receive(:capture3).and_wrap_original do |original, *args, **kwargs|
      count += 1 if args.include?('check-ignore') || args.include?('ls-files')
      original.call(*args, **kwargs)
    end
    yield
    count
  end

  describe '#skip_reasons' do
    it 'gives each path the answer #skip_reason gives it' do
      expected = paths.to_h { |path| [path, described_class.new(root: root).skip_reason(path)] }

      expect(expected).to eq('config/tracked.rb' => nil, 'config/ignored_tracked.rb' => 'git_ignored',
                             'config/local.yml' => 'git_ignored', 'config/untracked.rb' => 'untracked',
                             'config/odd name.rb' => nil)
      expect(filter.skip_reasons(paths)).to eq(expected)
    end

    it 'keys absolute paths as given' do
      absolute = File.join(root, 'config/untracked.rb')

      expect(filter.skip_reasons([absolute])).to eq(absolute => 'untracked')
    end

    it 'asks git once for ignores and once for the index, confirming only untracked verdicts' do
      filter.available?

      # check-ignore, ls-files, and one confirmation for config/untracked.rb
      expect(git_processes { filter.skip_reasons(paths) }).to eq(3)
    end

    it 'answers nil for every path when the filter is unavailable' do
      unavailable = described_class.new(root: nil)

      expect(unavailable.skip_reasons(paths)).to eq(paths.to_h { |path| [path, nil] })
    end

    it 'falls back to one query per path when a batch query fails' do
      allow(Open3).to receive(:capture3).and_wrap_original do |original, *args, **kwargs|
        if args.include?('--stdin')
          next ['', 'fatal',
                instance_double(Process::Status, success?: false, exitstatus: 128)]
        end

        original.call(*args, **kwargs)
      end

      expect(filter.skip_reasons(paths)['config/local.yml']).to eq('git_ignored')
      expect(filter.skip_reasons(paths)['config/untracked.rb']).to eq('untracked')
    end
  end

  describe '#prefetch' do
    it 'answers each prefetched path once from the batch, then asks git again' do
      filter.prefetch(paths)

      expect(git_processes { expect(filter.skip_reason('config/tracked.rb')).to be_nil }).to eq(0)
      expect(git_processes { expect(filter.skip_reason('config/tracked.rb')).to be_nil }).to eq(2)
    end

    it 'keeps no answer past #discard_prefetched' do
      filter.prefetch(paths)
      git('add', '--force', 'config/local.yml')
      File.write(File.join(root, '.gitignore'), '')
      filter.discard_prefetched

      expect(filter.skip_reason('config/local.yml')).to be_nil
    end
  end
end
