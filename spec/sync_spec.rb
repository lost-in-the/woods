# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'pathname'
require 'tmpdir'
require 'woods/sync'

# Cursor-based incremental sync (`rake woods:sync`).
#
# Encapsulates the loop every per-merge consumer used to hand-roll: remember
# the SHA of the last successful extraction (output_dir/.sync_head), diff
# cursor..HEAD, run an incremental extraction over the changed files, fall
# back to a full extract when there's no index/cursor/resolvable diff, and
# advance the cursor only after success. The cursor is owned by the side
# running `woods:sync` — which has working git by construction —
# deliberately NOT manifest.git_sha, which is "unknown" when extraction runs
# in a container that can't resolve a linked worktree's gitdir (#137).
RSpec.describe Woods::Sync do
  let(:tmpdir) { Dir.mktmpdir('woods_sync_test') }
  let(:root) { Pathname.new(tmpdir) }
  let(:output_dir) { File.join(tmpdir, 'tmp/woods') }

  let(:extractor) do
    instance_double(
      Woods::Extractor,
      extract_all: { models: [] },
      extract_changed: %w[Post],
      removed_unit_ids: [],
      unhandled_changed_files: []
    )
  end

  # Injectable git: receives the argv after `git -C <root>`, returns stdout
  # (String) on success or nil on failure — same contract as Sync#run_git.
  let(:git_responses) { {} }
  let(:git) do
    lambda do |*args|
      key = args.join(' ')
      raise "unexpected git call: #{key}" unless git_responses.key?(key)

      git_responses[key]
    end
  end

  subject(:sync) { described_class.new(output_dir: output_dir, root: root, extractor: extractor, git: git) }

  before do
    stub_const('Rails', double('Rails'))
    allow(Rails).to receive(:root).and_return(root)
    allow(Rails).to receive(:logger).and_return(double('Logger').as_null_object)
  end

  after { FileUtils.rm_rf(tmpdir) }

  def write_index!
    FileUtils.mkdir_p(output_dir)
    File.write(File.join(output_dir, 'manifest.json'), '{"total_units": 1, "counts": {"models": 1}}')
  end

  def write_cursor!(sha)
    FileUtils.mkdir_p(output_dir)
    File.write(File.join(output_dir, described_class::CURSOR_FILENAME), sha)
  end

  def cursor_on_disk
    path = File.join(output_dir, described_class::CURSOR_FILENAME)
    File.exist?(path) ? File.read(path).strip : nil
  end

  describe 'first run (no cursor)' do
    it 'runs a full extraction and writes the cursor to HEAD' do
      git_responses['rev-parse HEAD'] = "aaa111\n"
      write_index!

      result = sync.run

      expect(extractor).to have_received(:extract_all)
      expect(result.mode).to eq(:full)
      expect(result.reason).to eq(:no_cursor)
      expect(cursor_on_disk).to eq('aaa111')
    end
  end

  describe 'missing index (cursor present but no manifest)' do
    it 'falls back to a full extraction and advances the cursor' do
      git_responses['rev-parse HEAD'] = 'bbb222'
      write_cursor!('aaa111')

      result = sync.run

      expect(extractor).to have_received(:extract_all)
      expect(result.mode).to eq(:full)
      expect(result.reason).to eq(:no_index)
      expect(cursor_on_disk).to eq('bbb222')
    end
  end

  describe 'git unavailable' do
    it 'runs a full extraction but does not write a cursor' do
      git_responses['rev-parse HEAD'] = nil
      write_index!

      result = sync.run

      expect(extractor).to have_received(:extract_all)
      expect(result.mode).to eq(:full)
      expect(result.reason).to eq(:git_unavailable)
      expect(cursor_on_disk).to be_nil
    end
  end

  describe 'cursor already at HEAD' do
    it 'does nothing' do
      git_responses['rev-parse HEAD'] = 'aaa111'
      write_index!
      write_cursor!('aaa111')

      result = sync.run

      expect(extractor).not_to have_received(:extract_all)
      expect(extractor).not_to have_received(:extract_changed)
      expect(result.mode).to eq(:up_to_date)
    end
  end

  describe 'incremental sync' do
    before do
      git_responses['rev-parse HEAD'] = 'ccc333'
      git_responses['diff --name-only aaa111 ccc333'] =
        "app/models/post.rb\napp/services/grow_service.rb\nREADME.md\n"
      write_index!
      write_cursor!('aaa111')
    end

    it 'extracts only relevant changed files and advances the cursor' do
      result = sync.run

      expect(extractor).to have_received(:extract_changed)
        .with(%w[app/models/post.rb app/services/grow_service.rb])
      expect(result.mode).to eq(:incremental)
      expect(result.changed_files).to eq(%w[app/models/post.rb app/services/grow_service.rb])
      expect(result.affected).to eq(%w[Post])
      expect(cursor_on_disk).to eq('ccc333')
    end

    it 'does not advance the cursor when extraction raises' do
      allow(extractor).to receive(:extract_changed).and_raise(Woods::ExtractionError, 'boom')

      expect { sync.run }.to raise_error(Woods::ExtractionError)
      expect(cursor_on_disk).to eq('aaa111')
    end
  end

  describe 'diff with only irrelevant changes' do
    it 'advances the cursor without extracting' do
      git_responses['rev-parse HEAD'] = 'ccc333'
      git_responses['diff --name-only aaa111 ccc333'] = "README.md\ndocs/guide.md\n"
      write_index!
      write_cursor!('aaa111')

      result = sync.run

      expect(extractor).not_to have_received(:extract_changed)
      expect(result.mode).to eq(:up_to_date)
      expect(cursor_on_disk).to eq('ccc333')
    end
  end

  describe 'unresolvable diff (unknown cursor SHA — force push, shallow clone, gc)' do
    it 'falls back to a full extraction and advances the cursor' do
      git_responses['rev-parse HEAD'] = 'ccc333'
      git_responses['diff --name-only ddd444 ccc333'] = nil
      write_index!
      write_cursor!('ddd444')

      result = sync.run

      expect(extractor).to have_received(:extract_all)
      expect(result.mode).to eq(:full)
      expect(result.reason).to eq(:diff_failed)
      expect(cursor_on_disk).to eq('ccc333')
    end
  end

  describe 'deleted files' do
    it 'passes deleted paths through to extract_changed (B-065 removes their units)' do
      git_responses['rev-parse HEAD'] = 'ccc333'
      git_responses['diff --name-only aaa111 ccc333'] = "app/models/felled.rb\n"
      allow(extractor).to receive(:removed_unit_ids).and_return(%w[Felled])
      write_index!
      write_cursor!('aaa111')

      result = sync.run

      expect(extractor).to have_received(:extract_changed).with(%w[app/models/felled.rb])
      expect(result.removed_units).to eq(%w[Felled])
    end
  end
end
