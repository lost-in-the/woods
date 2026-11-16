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

  # Full and incremental runs decide the table the same way.
  def refresh
    # Each call represents a new extraction run, whose entry point clears
    # the previous capture before resolving the table's inputs.
    extractor.send(:reset_git_capture)
    extractor.send(:refresh_commit_table)
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
    expect(refresh).to eq(:written)

    table = Woods::GitCommitTable.read(output)
    expect(table['head']).to eq(git('rev-parse', 'HEAD'))
    expect(table['paths'].keys).to eq(['app/models/post.rb'])
    expect(table['commits'].first['files'].map { |file| file['path'] })
      .to eq(%w[app/models/post.rb lib/framework.rb vendor/bundle/gem.rb])
  end

  it 'keeps the seeded table on an incremental run whose inputs are unchanged, without walking history' do
    refresh
    before = File.binread(table_path)
    expect_any_instance_of(Woods::GitCommitTable).not_to receive(:build)

    expect(refresh).to be_nil
    expect(File.binread(table_path)).to eq(before)
  end

  it 'rebuilds the whole table when HEAD moves or the indexed path set changes' do
    refresh
    moved = commit('Add comment', { 'app/models/comment.rb' => 'class Comment; end' })

    expect(refresh).to eq(:written)
    expect(Woods::GitCommitTable.read(output)).to include('head' => moved, 'paths' => { 'app/models/post.rb' => [
                                                            git('rev-parse', 'HEAD~1')
                                                          ] })

    register(:model, 'Comment', root.join('app/models/comment.rb'))
    expect(refresh).to eq(:written)
    expect(Woods::GitCommitTable.read(output)['paths'].keys).to eq(%w[app/models/comment.rb app/models/post.rb])
  end

  it 'matches the bytes a full run writes after an incremental rebuild' do
    refresh
    commit('Edit post', { 'app/models/post.rb' => 'class Post; def a; end; end' })
    refresh
    incremental = File.binread(table_path)

    full = described_class.new(output_dir: root.join('oracle'))
    FileUtils.mkdir_p(root.join('oracle'))
    full.instance_variable_set(:@dependency_graph, extractor.dependency_graph)
    full.send(:refresh_commit_table)

    expect(File.binread(root.join('oracle', Woods::GitCommitTable::FILENAME))).to eq(incremental)
  end

  it 'withdraws a seeded table when the application has no readable history' do
    refresh
    FileUtils.rm_rf(root.join('.git'))

    expect(refresh).to eq(:withdrawn)
    expect(table_path).not_to exist
    expect(described_class.new(output_dir: output).send(:refresh_commit_table)).to be_nil
  end

  it 'withdraws the table when the walk fails rather than publishing a partial one' do
    refresh
    commit('Edit post', { 'app/models/post.rb' => 'changed' })
    allow_any_instance_of(Woods::GitCommitTable).to receive(:build).and_return(nil)

    expect(refresh).to eq(:withdrawn)
    expect(table_path).not_to exist
  end

  it 'rebuilds over an unreadable seeded copy' do
    File.write(table_path, '{')

    expect(refresh).to eq(:written)
    expect(Woods::GitCommitTable.read(output)['head']).to eq(git('rev-parse', 'HEAD'))
  end

  describe 'on a full run over a published table' do
    around do |example|
      original = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      example.run
    ensure
      Woods.configuration = original
    end

    before { refresh }

    def refresh_noting_walk
      walked = false
      # Ruby 3.0 and 3.1 splat the paths array into a block that names the
      # original method beside a keyword parameter, so take them all as one.
      allow_any_instance_of(Woods::GitCommitTable).to receive(:build).and_wrap_original do |*arguments, **keywords|
        walked = true
        original, *rest = arguments
        original.call(*rest, **keywords)
      end
      result = refresh
      [walked, result]
    end

    it 'reuses the published table when every input matches, without walking history' do
      before = File.binread(table_path)

      expect(refresh_noting_walk).to eq([false, nil])
      expect(File.binread(table_path)).to eq(before)
    end

    it 'walks again when HEAD moves' do
      commit('Edit post', { 'app/models/post.rb' => 'class Post; def a; end; end' })

      expect(refresh_noting_walk).to eq([true, :written])
    end

    it 'walks again when the indexed path set changes' do
      commit('Add comment', { 'app/models/comment.rb' => 'class Comment; end' })
      refresh
      register(:model, 'Comment', root.join('app/models/comment.rb'))

      expect(refresh_noting_walk).to eq([true, :written])
    end

    it "walks again when the window's first UTC day moves" do
      tomorrow = Time.now + 86_400
      allow(Time).to receive(:now).and_return(tomorrow)

      expect(refresh_noting_walk).to eq([true, :written])
    end

    {
      git_commit_table_days: 30, git_commit_table_limit: 10, git_commit_table_files_limit: 3,
      git_commit_table_line_stats: false, git_commit_table_hunk_budget: 7
    }.each do |setting, value|
      it "walks again when #{setting} changes" do
        Woods.configuration.public_send(:"#{setting}=", value)

        expect(refresh_noting_walk).to eq([true, :written])
      end
    end

    it 'walks again over an unreadable published table rather than trusting it' do
      File.write(table_path, '{')

      expect(refresh_noting_walk).to eq([true, :written])
      expect(Woods::GitCommitTable.read(output)['head']).to eq(git('rev-parse', 'HEAD'))
    end

    it 'keeps a withdrawn table withdrawn when the history is still unreadable' do
      FileUtils.rm_rf(root.join('.git'))
      expect(refresh).to eq(:withdrawn)

      expect(refresh).to be_nil
      expect(table_path).not_to exist
    end

    # Replace refs and grafts change the history git walks without moving
    # HEAD. Full and incremental runs both decide the table here, in
    # #refresh_commit_table, so one example per form covers both modes.
    describe 'when replace refs or grafts rewrite the history' do
      let(:original_root) { git('rev-list', '--max-parents=0', 'HEAD') }

      before do
        commit('Edit post', { 'app/models/post.rb' => 'class Post; def a; end; end' })
        refresh
        @plain = File.binread(table_path)
      end

      def messages
        Woods::GitCommitTable.read(output)['commits'].map { |row| row['message'] }
      end

      def replace_root_commit
        stand_in = git('commit-tree', "#{original_root}^{tree}", '-m', 'Stand-in for the first commit')
        git('replace', original_root, stand_in)
      end

      it 'records no rewrite state for a plain history, so its bytes are as before' do
        expect(Woods::GitCommitTable.read(output)).not_to have_key('history_rewrites')
      end

      it 'walks again while a replace ref is added, kept or removed, and reuses once it is unchanged' do
        replace_root_commit
        expect(refresh_noting_walk).to eq([true, :written])
        expect(messages).to eq(['Edit post', 'Stand-in for the first commit'])
        expect(refresh_noting_walk).to eq([false, nil])

        git('replace', '-d', original_root)
        expect(refresh_noting_walk).to eq([true, :written])
        expect(File.binread(table_path)).to eq(@plain)
        expect(refresh_noting_walk).to eq([false, nil])
      end

      it 'walks again when a replace ref is pointed at another commit' do
        replace_root_commit
        refresh
        other = git('commit-tree', "#{original_root}^{tree}", '-m', 'Another stand-in')
        git('replace', '-f', original_root, other)

        expect(refresh_noting_walk).to eq([true, :written])
        expect(messages).to eq(['Edit post', 'Another stand-in'])
      end

      it 'treats a table written before the field existed as current only while nothing rewrites history' do
        before = Woods::GitCommitTable.read(output)
        expect(before).not_to have_key('history_rewrites')
        expect(refresh_noting_walk).to eq([false, nil])

        replace_root_commit
        expect(refresh_noting_walk).to eq([true, :written])
      end

      it 'digests the refs in name order, whatever order they were made in' do
        stand_ins = Array.new(2) { |i| git('commit-tree', "#{original_root}^{tree}", '-m', "Stand-in #{i}") }
        git('replace', original_root, stand_ins.first)
        git('update-ref', 'refs/replace/zz-extra', stand_ins.last)
        first = Woods::Extraction::GitCapture.new(root: root, logger: double.as_null_object).history_rewrites
        git('update-ref', '-d', 'refs/replace/zz-extra')
        git('update-ref', 'refs/replace/zz-extra', stand_ins.last)

        expect(Woods::Extraction::GitCapture.new(root: root, logger: double.as_null_object).history_rewrites)
          .to eq(first).and match(/\A\h{64}\z/)
      end

      it 'walks again when a grafts file is written or removed' do
        grafts = root.join(git('rev-parse', '--git-path', 'info/grafts'))
        FileUtils.mkdir_p(grafts.dirname)
        File.write(grafts, "#{git('rev-parse', 'HEAD')}\n")
        expect(refresh_noting_walk).to eq([true, :written])
        expect(messages).to eq(['Edit post'])

        FileUtils.rm_f(grafts)
        expect(refresh_noting_walk).to eq([true, :written])
        expect(File.binread(table_path)).to eq(@plain)
      end

      it 'keeps the table when replacement is turned off, since the refs then change nothing' do
        replace_root_commit
        git('config', 'core.useReplaceRefs', 'false')

        expect(refresh_noting_walk).to eq([false, nil])
        expect(File.binread(table_path)).to eq(@plain)
      end

      it 'keeps the table under GIT_NO_REPLACE_OBJECTS' do
        replace_root_commit
        ENV['GIT_NO_REPLACE_OBJECTS'] = '1'

        expect(refresh_noting_walk).to eq([false, nil])
        expect(File.binread(table_path)).to eq(@plain)
      ensure
        ENV.delete('GIT_NO_REPLACE_OBJECTS')
      end

      it 'walks when the rewrite state cannot be read' do
        allow_any_instance_of(Woods::Extraction::GitCapture).to receive(:read_history_rewrites)
          .and_return(Woods::Extraction::GitCapture::REWRITES_UNKNOWN)

        expect(refresh_noting_walk).to eq([true, :written])
        expect(refresh_noting_walk).to eq([true, nil])
      end
    end

    # A shallow repository has no table (GitCapture#available? is false), so
    # deepening it can never leave a short table behind to reuse: the run
    # after `--unshallow` finds none and walks.
    it 'has no table to reuse while a clone is shallow, and walks once it is unshallowed' do
      commit('Edit post', { 'app/models/post.rb' => 'class Post; def a; end; end' })
      commit('Edit post again', { 'app/models/post.rb' => 'class Post; def b; end; end' })
      refresh
      complete = File.binread(table_path)
      origin = root.join('origin.git')
      git('clone', '-q', '--bare', '--no-local', root.to_s, origin.to_s)
      FileUtils.rm_rf(root.join('.git'))
      shallow = root.join('shallow')
      git('clone', '-q', '--depth', '1', "file://#{origin}", shallow.to_s)
      FileUtils.mv(shallow.join('.git'), root.join('.git'))

      expect(refresh).to eq(:withdrawn)
      git('fetch', '-q', '--deepen', '1')
      expect(git('rev-parse', '--is-shallow-repository')).to eq('true')
      expect(refresh).to be_nil
      expect(table_path).not_to exist

      git('fetch', '-q', '--unshallow')
      expect(refresh_noting_walk).to eq([true, :written])
      expect(File.binread(table_path)).to eq(complete)
    end

    it 'walks when the index was cleaned, so there is no published table' do
      FileUtils.rm_f(table_path)

      expect(refresh_noting_walk).to eq([true, :written])
    end
  end

  it 'keeps the configured number of recent commits per unit' do
    6.times { |i| commit("edit #{i}", { 'app/models/post.rb' => i.to_s }) }
    Woods.configure { |config| config.git_recent_commits = 7 }

    data = extractor.send(:git_capture).file_facts([model_path.to_s]).fetch('app/models/post.rb')

    expect(data[:commit_count]).to eq(7)
    expect(data[:recent_commits].size).to eq(7)
  ensure
    Woods.configure { |config| config.git_recent_commits = 5 }
  end
end
