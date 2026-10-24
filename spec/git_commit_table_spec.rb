# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/git_commit_table'
require 'tmpdir'
require 'fileutils'
require 'stringio'

RSpec.describe Woods::GitCommitTable do
  let(:root) { Dir.mktmpdir('woods_commit_table') }
  let(:logger) { double('Logger').as_null_object }
  let(:settings) { { 'window_days' => 365, 'max_commits' => 5000, 'max_files_per_commit' => 100 } }
  let(:today) { Time.now.utc.to_date }
  let(:table) { described_class.new(root: root, logger: logger, settings: settings, today: today) }

  def git(*args, env: {}, dir: root)
    output, status = Open3.capture2e(env, 'git', '-C', dir, *args)
    raise output unless status.success?

    output.strip
  end

  def commit(message, changes, days_ago: 0, author: 'Author', remove: [])
    changes.each do |path, content|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), content)
    end
    remove.each { |path| git('rm', '-q', path) }
    git('add', '-A')
    date = (Time.now - (days_ago * 86_400)).iso8601
    git('commit', '-qm', message, env: { 'GIT_AUTHOR_DATE' => date, 'GIT_COMMITTER_DATE' => date,
                                         'GIT_AUTHOR_NAME' => author })
    git('rev-parse', 'HEAD')
  end

  def head
    git('rev-parse', 'HEAD')
  end

  before do
    git('init', '-qb', 'main')
    git('config', 'user.name', 'Author')
    git('config', 'user.email', 'test@example.invalid')
  end

  after { FileUtils.rm_rf(root) }

  describe '#build' do
    it 'publishes the indexed commits newest first with their files, and the path table' do
      commit('too old', { 'app/models/post.rb' => 'v0' }, days_ago: 400)
      first = commit('Add post', { 'app/models/post.rb' => 'v1', 'README.md' => 'readme' }, days_ago: 10,
                                                                                            author: 'Leah Armstrong')
      commit('Docs only', { 'README.md' => 'more' }, days_ago: 5)
      second = commit("Touch the author\n\nAuthors expect updated_at to move.\nSecond line.",
                      { 'app/models/post.rb' => 'v2', 'app/controllers/posts_controller.rb' => 'c' },
                      days_ago: 3, author: 'Sam Okafor-Whitfield')

      result = table.build(%w[app/controllers/posts_controller.rb app/models/post.rb], head: head)

      expect(result.keys).to eq(%w[schema_version head since window_days max_commits max_files_per_commit
                                   indexed_paths_sha256 truncated commits paths])
      expect(result).to include('schema_version' => 1, 'head' => second, 'window_days' => 365,
                                'since' => (today - 365).iso8601, 'truncated' => false)
      expect(result['commits'].map { |row| row['sha'] }).to eq([second, first])
      latest = result['commits'].first
      expect(latest.keys).to eq(%w[sha parents author date message description files files_omitted])
      expect(latest).to include('author' => 'Sam Okafor-Whitfield', 'message' => 'Touch the author',
                                'description' => "Authors expect updated_at to move.\nSecond line.",
                                'parents' => [git('rev-parse', 'HEAD~1')], 'files_omitted' => 0)
      expect(Time.iso8601(latest['date'])).to be_within(2).of(Time.now - (3 * 86_400))
      expect(latest['files']).to eq([
                                      { 'path' => 'app/controllers/posts_controller.rb', 'status' => 'added' },
                                      { 'path' => 'app/models/post.rb', 'status' => 'modified' }
                                    ])
      expect(result['commits'].last['files']).to include({ 'path' => 'README.md', 'status' => 'added' })
      expect(result['commits'].last['description']).to eq('')
      expect(result['paths']).to eq('app/controllers/posts_controller.rb' => [second],
                                    'app/models/post.rb' => [second, first])
    end

    it 'records deletions and keeps only paths inside a nested application root' do
      commit('root', { 'apps/web/app/models/post.rb' => 'a', 'apps/web/lib/old.rb' => 'x', 'other/x.rb' => 'y' })
      sha = commit('remove old', { 'apps/web/app/models/post.rb' => 'b', 'other/x.rb' => 'z' },
                   remove: ['apps/web/lib/old.rb'])
      nested = described_class.new(root: File.join(root, 'apps/web'), logger: logger, settings: settings,
                                   today: today)

      result = nested.build(%w[app/models/post.rb], head: head)

      expect(result['commits'].first).to include('sha' => sha, 'files' => [
                                                   { 'path' => 'app/models/post.rb', 'status' => 'modified' },
                                                   { 'path' => 'lib/old.rb', 'status' => 'deleted' }
                                                 ])
      expect(result['paths'].keys).to eq(['app/models/post.rb'])
    end

    it 'diffs a merge against its first parent and lists both parents' do
      commit('root', { 'app/a.rb' => 'a', 'app/b.rb' => 'b' })
      git('checkout', '-qb', 'side')
      side = commit('side', { 'app/a.rb' => 'side' })
      git('checkout', '-q', 'main')
      main = commit('main', { 'app/b.rb' => 'main' })
      git('merge', '--no-ff', '-qm', 'merge side', 'side')

      merge = table.build(%w[app/a.rb app/b.rb], head: head)['commits'].first

      expect(merge).to include('message' => 'merge side', 'parents' => [main, side],
                               'files' => [{ 'path' => 'app/a.rb', 'status' => 'modified' }])
    end

    it 'keeps the newest commits within the bound and says the table is truncated' do
      shas = Array.new(4) { |i| commit("change #{i}", { 'app/a.rb' => i.to_s }, days_ago: 4 - i) }
      bounded = described_class.new(root: root, logger: logger, settings: settings.merge('max_commits' => 2),
                                    today: today)

      result = bounded.build(%w[app/a.rb], head: head)

      expect(result).to include('truncated' => true, 'max_commits' => 2)
      expect(result['commits'].map { |row| row['sha'] }).to eq(shas.last(2).reverse)
      expect(result['paths']).to eq('app/a.rb' => shas.last(2).reverse)
    end

    it 'caps the files listed per commit and counts the rest' do
      commit('wide', (1..5).to_h { |i| ["app/f#{i}.rb", 'x'] })
      capped = described_class.new(root: root, logger: logger,
                                   settings: settings.merge('max_files_per_commit' => 2), today: today)

      row = capped.build(%w[app/f5.rb], head: head)['commits'].first

      expect(row['files'].map { |file| file['path'] }).to eq(%w[app/f1.rb app/f2.rb])
      expect(row['files_omitted']).to eq(3)
    end

    it 'walks the given head, not whatever HEAD has moved to' do
      pinned = commit('first', { 'app/a.rb' => '1' })
      commit('second', { 'app/a.rb' => '2' })

      result = table.build(%w[app/a.rb], head: pinned)

      expect(result['commits'].map { |row| row['message'] }).to eq(['first'])
    end

    it 'publishes an empty table, not an absent one, when no indexed path changed in the window' do
      commit('old', { 'app/a.rb' => '1' }, days_ago: 400)

      result = table.build(%w[app/a.rb], head: head)

      expect(result).to include('commits' => [], 'paths' => {}, 'truncated' => false)
    end

    it 'answers nil and warns once when the history cannot be read completely' do
      commit('root', { 'app/a.rb' => 'a' })
      allow(Open3).to receive(:capture3).and_return(["\n", '', double(success?: true)])
      wait = double('Wait', value: double('Status', success?: true, exitstatus: 0))
      allow(Open3).to receive(:popen3).and_yield(StringIO.new, StringIO.new("\0#{'a' * 40}\0\0Author"),
                                                 StringIO.new, wait)
      expect(logger).to receive(:warn).once.with(/commit table omitted/)

      expect(table.build(%w[app/a.rb], head: 'a' * 40)).to be_nil
    end
  end

  describe '#key and .current?' do
    it 'matches a table built from the same head, paths and settings, and nothing else' do
      commit('root', { 'app/a.rb' => 'a', 'app/b.rb' => 'b' })
      built = table.build(%w[app/a.rb], head: head)

      expect(described_class.current?(built, table.key(%w[app/a.rb], head: head))).to be(true)
      expect(described_class.current?(built, table.key(%w[app/a.rb app/b.rb], head: head))).to be(false)
      expect(described_class.current?(built, table.key(%w[app/a.rb], head: 'b' * 40))).to be(false)
      wider = described_class.new(root: root, logger: logger, settings: settings.merge('window_days' => 30),
                                  today: today)
      expect(described_class.current?(built, wider.key(%w[app/a.rb], head: head))).to be(false)
      tomorrow = described_class.new(root: root, logger: logger, settings: settings, today: today + 1)
      expect(described_class.current?(built, tomorrow.key(%w[app/a.rb], head: head))).to be(false)
      expect(described_class.current?(nil, table.key(%w[app/a.rb], head: head))).to be(false)
    end
  end

  describe '.write, .read and .delete' do
    let(:payload) { Pathname.new(Dir.mktmpdir('woods_commit_payload')) }

    after { FileUtils.rm_rf(payload) }

    it 'round-trips the table and treats a missing file as no table' do
      expect(described_class.read(payload)).to be_nil
      commit('root', { 'app/a.rb' => 'ä' }, author: 'Åsa')
      built = table.build(%w[app/a.rb], head: head)

      described_class.write(payload, built, durable: false)

      expect(described_class.read(payload)).to eq(built)
      described_class.delete(payload)
      expect(described_class.read(payload)).to be_nil
      expect { described_class.delete(payload) }.not_to raise_error
    end
  end

  describe '.settings' do
    it 'reads the configured bounds and falls back to the documented defaults' do
      expect(described_class.settings(nil)).to eq('window_days' => 365, 'max_commits' => 5000,
                                                  'max_files_per_commit' => 100)
      config = Woods::Configuration.new
      config.git_commit_table_days = 90
      config.git_commit_table_limit = 200
      config.git_commit_table_files_limit = 20

      expect(described_class.settings(config)).to eq('window_days' => 90, 'max_commits' => 200,
                                                     'max_files_per_commit' => 20)
    end
  end
end
