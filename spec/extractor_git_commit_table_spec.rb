# frozen_string_literal: true

require 'spec_helper'
require 'active_support/all'
require 'woods'
require 'woods/extractor'
require 'tmpdir'
require 'open3'

RSpec.describe Woods::Extractor, 'commit table' do
  let(:root) { Pathname.new(Dir.mktmpdir('woods_commit_table_run')) }
  let(:output) { root.join('output') }
  let(:extractor) { described_class.new(output_dir: output) }
  let(:model_path) { root.join('app/models/post.rb') }
  let(:table_path) { output.join(Woods::GitCommitTable::FILENAME) }

  def git(*args)
    output, status = Open3.capture2e('git', '-C', root.to_s, *args)
    raise output unless status.success?

    output.strip
  end

  def commit(message, changes)
    changes.each do |path, content|
      FileUtils.mkdir_p(root.join(path).dirname)
      File.write(root.join(path), content)
    end
    git('add', '-A', '--', *changes.keys)
    git('commit', '-qm', message)
    git('rev-parse', 'HEAD')
  end

  def register(type, identifier, path)
    extractor.dependency_graph.register(Woods::ExtractedUnit.new(type: type, identifier: identifier,
                                                                 file_path: path.to_s))
  end

  def refresh(full:)
    extractor.send(:refresh_commit_table, full: full)
  end

  before do
    stub_const('Rails', double('Rails', root: root, logger: double('Logger').as_null_object))
    FileUtils.mkdir_p(output)
    git('init', '-q', '-b', 'main')
    git('config', 'user.name', 'Main Author')
    git('config', 'user.email', 'test@example.invalid')
    commit('Add post', { 'app/models/post.rb' => 'class Post; end', 'vendor/bundle/gem.rb' => 'x',
                         'lib/framework.rb' => 'x' })
    register(:model, 'Post', model_path)
    register(:service, 'Vendored', root.join('vendor/bundle/gem.rb'))
    register(:rails_source, 'rails/framework', root.join('lib/framework.rb'))
  end

  after { FileUtils.rm_rf(root) }

  it 'publishes the indexed application paths of the final graph on a full run' do
    expect(refresh(full: true)).to eq(:written)

    table = Woods::GitCommitTable.read(output)
    expect(table['head']).to eq(git('rev-parse', 'HEAD'))
    expect(table['paths'].keys).to eq(['app/models/post.rb'])
    expect(table['commits'].first['files'].map { |file| file['path'] })
      .to eq(%w[app/models/post.rb lib/framework.rb vendor/bundle/gem.rb])
  end

  it 'keeps the seeded table on an incremental run whose inputs are unchanged, without walking history' do
    refresh(full: true)
    before = File.binread(table_path)
    expect_any_instance_of(Woods::GitCommitTable).not_to receive(:build)

    expect(refresh(full: false)).to be_nil
    expect(File.binread(table_path)).to eq(before)
  end

  it 'rebuilds the whole table when HEAD moves or the indexed path set changes' do
    refresh(full: true)
    moved = commit('Add comment', { 'app/models/comment.rb' => 'class Comment; end' })

    expect(refresh(full: false)).to eq(:written)
    expect(Woods::GitCommitTable.read(output)).to include('head' => moved, 'paths' => { 'app/models/post.rb' => [
                                                            git('rev-parse', 'HEAD~1')
                                                          ] })

    register(:model, 'Comment', root.join('app/models/comment.rb'))
    expect(refresh(full: false)).to eq(:written)
    expect(Woods::GitCommitTable.read(output)['paths'].keys).to eq(%w[app/models/comment.rb app/models/post.rb])
  end

  it 'matches the bytes a full run writes after an incremental rebuild' do
    refresh(full: true)
    commit('Edit post', { 'app/models/post.rb' => 'class Post; def a; end; end' })
    refresh(full: false)
    incremental = File.binread(table_path)

    full = described_class.new(output_dir: root.join('oracle'))
    FileUtils.mkdir_p(root.join('oracle'))
    full.instance_variable_set(:@dependency_graph, extractor.dependency_graph)
    full.send(:refresh_commit_table, full: true)

    expect(File.binread(root.join('oracle', Woods::GitCommitTable::FILENAME))).to eq(incremental)
  end

  it 'withdraws a seeded table when the application has no readable history' do
    refresh(full: true)
    FileUtils.rm_rf(root.join('.git'))

    expect(refresh(full: false)).to eq(:withdrawn)
    expect(table_path).not_to exist
    expect(described_class.new(output_dir: output).send(:refresh_commit_table, full: false)).to be_nil
  end

  it 'withdraws the table when the walk fails rather than publishing a partial one' do
    refresh(full: true)
    commit('Edit post', { 'app/models/post.rb' => 'changed' })
    allow_any_instance_of(Woods::GitCommitTable).to receive(:build).and_return(nil)

    expect(refresh(full: false)).to eq(:withdrawn)
    expect(table_path).not_to exist
  end

  it 'rebuilds over an unreadable seeded copy' do
    File.write(table_path, '{')

    expect(refresh(full: false)).to eq(:written)
    expect(Woods::GitCommitTable.read(output)['head']).to eq(git('rev-parse', 'HEAD'))
  end

  it 'keeps the configured number of recent commits per unit' do
    6.times { |i| commit("edit #{i}", { 'app/models/post.rb' => i.to_s }) }
    Woods.configure { |config| config.git_recent_commits = 7 }

    data = extractor.send(:batch_git_data, [model_path.to_s]).fetch('app/models/post.rb')

    expect(data[:commit_count]).to eq(7)
    expect(data[:recent_commits].size).to eq(7)
  ensure
    Woods.configure { |config| config.git_recent_commits = 5 }
  end
end
