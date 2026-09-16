# frozen_string_literal: true

require 'spec_helper'
require 'woods/git_history'
require 'tmpdir'
require 'fileutils'
require 'stringio'

RSpec.describe Woods::GitHistory do
  let(:root) { Dir.mktmpdir('woods_git_events') }
  let(:logger) { double('Logger').as_null_object }
  let(:reader) { described_class.new(root: root, logger: logger) }

  def git(*args, env: {})
    output, status = Open3.capture2e(env, 'git', '-C', root, *args)
    raise output unless status.success?

    output.strip
  end

  def commit(message, changes, days_ago: 0, author: 'Author')
    changes.each do |path, content|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), content)
    end
    git('add', '-A')
    date = (Time.now - (days_ago * 86_400)).iso8601
    git('commit', '-qm', message, env: { 'GIT_AUTHOR_DATE' => date, 'GIT_COMMITTER_DATE' => date,
                                         'GIT_AUTHOR_NAME' => author })
  end

  def read(*paths)
    reader.read(paths, recent_after: Time.now - (90 * 86_400))
  end

  before do
    git('init', '-qb', 'main')
    git('config', 'user.name', 'Author')
    git('config', 'user.email', 'test@example.invalid')
  end

  after { FileUtils.rm_rf(root) }

  it 'preserves literal filenames and commit fields without delimiter collisions' do
    names = [' leading trailing ', "tab\tfile", "line\nfile", '__COMMIT__name', ':raw-like', 'café.rb', 'a' * 40]
    commit('subject ||| __COMMIT__ delimiters', names.to_h { |name| [name, 'a'] }, author: 'Åuthor ||| Name')

    result = read(*names)
    expect(result.keys).to eq(names)
    result.each_value do |data|
      expect(data[:commit_count]).to eq(1)
      expect(data[:commits].first).to include(message: 'subject ||| __COMMIT__ delimiters', author: 'Åuthor ||| Name')
    end
  end

  it 'counts HEAD-reachable side commits through an ours merge independently of requested paths' do
    commit('root', { 'target.rb' => 'base', 'other.rb' => 'base' })
    git('checkout', '-qb', 'side')
    commit('side change', { 'target.rb' => 'side' })
    git('checkout', '-q', 'main')
    commit('main change', { 'other.rb' => 'main' })
    git('merge', '-s', 'ours', '--no-ff', '-qm', 'discard side', 'side')

    single = read('target.rb').fetch('target.rb')
    expect(single).to eq(read('target.rb', 'other.rb').fetch('target.rb'))
    expect(single[:commits].map { |entry| entry[:message] }).to contain_exactly('root', 'side change')
  end

  it 'counts an ordinary merge introduction and its side commit as separate events' do
    commit('root', { 'target.rb' => 'base' })
    git('checkout', '-qb', 'side')
    commit('side change', { 'target.rb' => 'side' })
    git('checkout', '-q', 'main')
    git('merge', '--no-ff', '-qm', 'introduce side', 'side')

    expect(read('target.rb').fetch('target.rb')[:commits].map { |entry| entry[:message] })
      .to contain_exactly('root', 'side change', 'introduce side')
  end

  it 'counts a conflict-resolution merge once against its first parent plus both ancestors' do
    commit('root', { 'target.rb' => "base\n" })
    git('checkout', '-qb', 'side')
    commit('side change', { 'target.rb' => "side\n" })
    git('checkout', '-q', 'main')
    commit('main change', { 'target.rb' => "main\n" })
    _output, status = Open3.capture2e('git', '-C', root, 'merge', '--no-ff', 'side')
    expect(status.success?).to be(false)
    commit('resolution', { 'target.rb' => "resolved\n" })

    expect(read('target.rb').fetch('target.rb')[:commits].map { |entry| entry[:message] })
      .to contain_exactly('root', 'side change', 'main change', 'resolution')
  end

  it 'treats a rename as a deletion and addition without following the old name' do
    commit('old root', { 'old.rb' => 'same' })
    git('mv', 'old.rb', 'new.rb')
    git('commit', '-qm', 'rename')

    expect(read('new.rb').fetch('new.rb')[:commits].map { |entry| entry[:message] }).to eq(['rename'])
  end

  it 'counts deletion and recreation at the same exact name' do
    commit('original', { 'sample.rb' => 'old' })
    git('rm', '-q', 'sample.rb')
    git('commit', '-qm', 'delete')
    commit('recreated', { 'sample.rb' => 'new' })

    expect(read('sample.rb').fetch('sample.rb')[:commits].map { |entry| entry[:message] })
      .to contain_exactly('original', 'delete', 'recreated')
  end

  it 'uses committer instants for the recent window despite author dates and timezone offsets' do
    cutoff = Time.now - (90 * 86_400)
    [cutoff - 3600, cutoff + 3600].each_with_index do |instant, index|
      File.write(File.join(root, 'sample.rb'), index.to_s)
      git('add', 'sample.rb')
      committer = instant.getlocal(index.zero? ? '+14:00' : '-12:00').iso8601
      git('commit', '-qm', "change #{index}", env: {
            'GIT_COMMITTER_DATE' => committer,
            'GIT_AUTHOR_DATE' => (Time.now - (index.zero? ? 0 : 200 * 86_400)).iso8601
          })
    end

    data = reader.read(['sample.rb'], recent_after: cutoff).fetch('sample.rb')
    expect(data).to include(commit_count: 2, recent_count: 1)
    expect(Time.iso8601(data[:last_modified])).to be_within(1).of(cutoff + 3600)
  end

  it 'maps repository paths into a nested Rails root without including siblings' do
    commit('root', { 'apps/nested/sample.rb' => 'yes', 'sample.rb' => 'no' })
    commit('sibling-only change', { 'sample.rb' => 'changed sibling' })
    git('config', 'diff.relative', 'true')
    nested = described_class.new(root: File.join(root, 'apps/nested'), logger: logger)
    result = nested.read(['sample.rb'], recent_after: Time.now - 86_400)
    expect(result.fetch('sample.rb')[:commit_count]).to eq(1)
  end

  it 'keeps total and recent counts while retaining only five commit records' do
    commit('too old', { 'sample.rb' => 'old' }, days_ago: 400)
    commit('within year', { 'sample.rb' => 'year' }, days_ago: 100)
    8.times { |i| commit("recent #{i}", { 'sample.rb' => i.to_s }, author: "Author #{i % 2}") }

    data = read('sample.rb').fetch('sample.rb')
    expect(data).to include(commit_count: 9, recent_count: 8)
    expect(data[:contributors]).to eq('Author' => 1, 'Author 0' => 4, 'Author 1' => 4)
    expect(data[:commits].size).to eq(5)
    expect(data[:commits].map { |c| c[:message] }).not_to include('too old')
  end

  [false, true].each do |partial|
    it "discards #{partial ? 'partial output' : 'unsupported-option output'} on a failed command and warns once" do
      commit('root', { 'sample.rb' => 'a' })
      allow(Open3).to receive(:capture3).and_return(["\n", '', double(success?: true)])
      stream = if partial
                 "\0#{'a' * 40}\0Author\0#{Time.now.iso8601}\0subject\0\0" \
                   "\n:100644 100644 a b M\0sample.rb\0"
               else
                 ''
               end
      stdout = StringIO.new(stream)
      wait = double('Wait', value: double('Status', success?: false, exitstatus: 129))
      allow(Open3).to receive(:popen3).and_yield(StringIO.new, stdout, StringIO.new('unsupported option'), wait)
      expect(logger).to receive(:warn).once.with(/Git 2.31 or newer/)

      expect(read('sample.rb')).to be_nil
    end
  end

  it 'rejects an incomplete successful stream instead of publishing partial history' do
    commit('root', { 'sample.rb' => 'a' })
    allow(Open3).to receive(:capture3).and_return(["\n", '', double(success?: true)])
    wait = double('Wait', value: double('Status', success?: true, exitstatus: 0))
    allow(Open3).to receive(:popen3).and_yield(StringIO.new, StringIO.new("\0#{'a' * 40}\0Author"), StringIO.new, wait)
    expect(logger).to receive(:warn).once

    expect(read('sample.rb')).to be_nil
  end
end
