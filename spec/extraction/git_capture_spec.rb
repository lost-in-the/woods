# frozen_string_literal: true

require 'spec_helper'
require 'active_support/all'
require 'tmpdir'
require 'open3'
require 'woods'
require 'woods/dependency_graph'
require 'woods/extracted_unit'
require 'woods/extraction/git_capture'

RSpec.describe Woods::Extraction::GitCapture do
  let(:root) { Pathname.new(Dir.mktmpdir('woods_git_capture')) }
  let(:logger) { double('Logger').as_null_object }
  let(:capture) { described_class.new(root: root, logger: logger) }
  let(:path) { root.join('app/models/post.rb') }
  let(:graph) { Woods::DependencyGraph.new }

  def git(*args)
    output, status = Open3.capture2e('git', '-C', root.to_s, *args)
    raise output unless status.success?

    output.strip
  end

  def init_repository
    git('init', '-q', '-b', 'main')
    git('config', 'user.name', 'Main Author')
    git('config', 'user.email', 'test@example.invalid')
    FileUtils.mkdir_p(path.dirname)
    File.write(path, 'class Post; end')
    git('add', '-A')
    git('commit', '-qm', 'Add post')
    git('rev-parse', 'HEAD')
  end

  def register(type, identifier, file)
    graph.register(Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: file.to_s))
  end

  after { FileUtils.rm_rf(root) }

  describe 'HEAD capture' do
    it 'reads the commit and branch once, and later commits do not move it' do
      sha = init_repository
      expect(capture.head).to eq(sha)

      File.write(path, 'class Post; def a; end; end')
      git('commit', '-qam', 'Later')

      expect(capture.head).to eq(sha)
      expect(capture.provenance).to eq(git_sha: sha, git_branch: 'main')
    end

    it 'records a detached HEAD without a branch name' do
      sha = init_repository
      git('checkout', '-q', '--detach')

      expect(capture.head).to eq(sha)
      expect(capture.provenance).to eq(git_sha: sha, git_branch: Woods::GitProvenance::UNKNOWN)
    end

    it 'has no provenance until a fact is read, and never resolves HEAD for it' do
      init_repository
      allow(capture).to receive(:run_git).and_call_original

      expect(capture.provenance).to be_nil
      expect(capture).not_to have_received(:run_git)
    end

    it 'keeps a failed resolution failed for the rest of the run' do
      init_repository
      allow(capture).to receive(:run_git).and_call_original
      allow(capture).to receive(:run_git).with('rev-parse', '--verify', 'HEAD^{commit}').and_return('')
      allow(capture).to receive(:run_git).with('symbolic-ref', '--quiet', 'HEAD').and_return('')

      2.times { expect(capture.head).to be_nil }
      expect(capture.file_facts([path.to_s])).to eq({})
      expect(capture.commit_table(nil, graph: graph, full: true)).to be_nil
      expect(capture).to have_received(:run_git).with('rev-parse', '--verify', 'HEAD^{commit}').once
      expect(capture.provenance).to be_nil
    end

    it 'runs against the root rather than the process working directory' do
      init_repository

      expect(Pathname.new(capture.send(:run_git, 'rev-parse', '--show-toplevel')).realpath).to eq(root.realpath)
    end
  end

  describe '#available?' do
    it 'probes once per capture' do
      init_repository
      allow(Open3).to receive(:capture3).and_call_original

      2.times { expect(capture.available?).to be(true) }
      expect(Open3).to have_received(:capture3).with('git', '-C', root.to_s, 'rev-parse', 'HEAD').once
    end

    it 'answers no_repository quietly for a source archive' do
      expect(logger).not_to receive(:warn)

      expect(capture.availability).to eq(available: false, reason: 'no_repository')
    end
  end

  describe '#file_facts' do
    before { allow(capture).to receive(:head).and_return('a' * 40) }

    it 'returns no facts for no paths without reading history' do
      expect(Woods::GitHistory).not_to receive(:new)

      expect(capture.file_facts([])).to eq({})
    end

    it 'deduplicates root-relative paths into one history walk at the captured HEAD' do
      relative = (1..1100).map { |i| "file_#{i}.rb" }
      reader = instance_double(Woods::GitHistory)
      allow(Woods::GitHistory).to receive(:new).and_return(reader)
      expect(reader).to receive(:read).once.with(relative, recent_after: kind_of(Time), revision: 'a' * 40)
                                      .and_return(relative.to_h { |file| [file, {}] })

      facts = capture.file_facts(relative.flat_map { |file| [root.join(file).to_s] * 2 })

      expect(facts.size).to eq(1100)
    end

    it 'shapes published metadata with the configured recent commit limit' do
      commits = (1..4).map do |i|
        { sha: i.to_s * 40, message: "edit #{i}", date: Time.current.iso8601, author: 'A' }
      end
      reader = instance_double(Woods::GitHistory, read: { 'post.rb' => {
                                 commits: commits, commit_count: 12, recent_count: 4,
                                 contributors: { 'A' => 3, 'B' => 9 }, last_author: 'A', last_modified: 'today'
                               } })
      allow(Woods::GitHistory).to receive(:new).with(root: root, logger: logger, recent_limit: 2).and_return(reader)
      limited = described_class.new(root: root, logger: logger, recent_limit: 2)
      allow(limited).to receive(:head).and_return('a' * 40)

      facts = limited.file_facts([root.join('post.rb').to_s]).fetch('post.rb')

      expect(facts).to include(commit_count: 12, change_frequency: :active, last_author: 'A')
      expect(facts[:contributors]).to eq([{ name: 'B', commits: 9 }, { name: 'A', commits: 3 }])
      expect(facts[:recent_commits].map { |commit| commit[:sha] }).to eq(%w[11111111 22222222])
    end

    it 'publishes history_read_failed when the walk fails after HEAD resolved' do
      allow(Woods::GitHistory).to receive(:new).and_return(instance_double(Woods::GitHistory, read: nil))
      allow(capture).to receive(:availability).and_return(available: true, reason: nil)

      expect(capture.file_facts([path.to_s])).to eq({})
      expect(capture.enrichment_summary(graph: graph, full: true))
        .to include('state' => 'unavailable', 'reason' => 'history_read_failed', 'head_sha' => nil)
    end
  end

  describe '#enrichment_summary' do
    it 'counts every unit with facts as refreshed on a full run, and only noted units otherwise' do
      sha = init_repository
      register(:model, 'Post', path)
      register(:model, 'Comment', path)
      graph.annotate('Post', type: :model, commit_count: 1, change_frequency: :new)
      graph.annotate('Comment', type: :model, commit_count: 1, change_frequency: :new)
      capture.head

      expect(capture.enrichment_summary(graph: graph, full: true))
        .to include('state' => 'available', 'head_sha' => sha, 'capture' => { 'refreshed' => 2, 'retained' => 0 })

      capture.note_refreshed('Post', :model)
      expect(capture.enrichment_summary(graph: graph, full: false))
        .to include('capture' => { 'refreshed' => 1, 'retained' => 1 })
    end
  end

  describe '#request_recheck' do
    it 'collects the retained identifiers whose facts must be read again' do
      capture.request_recheck('Post')
      capture.request_recheck('Post')

      expect(capture.rechecks).to eq(Set['Post'])
    end
  end

  describe '#commit_table' do
    before do
      init_repository
      register(:model, 'Post', path)
      FileUtils.mkdir_p(root.join('vendor/bundle'))
      File.write(root.join('vendor/bundle/gem.rb'), 'x')
      register(:service, 'Vendored', root.join('vendor/bundle/gem.rb'))
      register(:rails_source, 'rails/base', path)
    end

    it 'builds the table over the application paths of the graph on a full run' do
      table = capture.commit_table(nil, graph: graph, full: true)

      expect(table['head']).to eq(git('rev-parse', 'HEAD'))
      expect(table['paths'].keys).to eq(['app/models/post.rb'])
    end

    it 'keeps a current published table on an incremental run without walking history' do
      published = described_class.new(root: root, logger: logger).commit_table(nil, graph: graph, full: true)
      expect_any_instance_of(Woods::GitCommitTable).not_to receive(:build)

      expect(capture.commit_table(published, graph: graph, full: false)).to equal(published)
    end

    it 'has no table without readable history' do
      FileUtils.rm_rf(root.join('.git'))

      expect(capture.commit_table({ 'head' => 'old' }, graph: graph, full: false)).to be_nil
    end
  end
end
