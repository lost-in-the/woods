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
  # (String) on success or nil on failure — same contract as the real
  # subprocess path. FAITHFULNESS MATTERS: real git appends a trailing
  # newline to stdout, so every fake response here must carry it too —
  # a pre-stripped fake once hid a newline-normalization bug that made
  # every sync after the first full-extract (see the run_git comment).
  let(:git_responses) { {} }
  let(:git) do
    lambda do |*args|
      key = args.join(' ')
      raise "unexpected git call: #{key}" unless git_responses.key?(key)

      response = git_responses[key]
      if response && !response.end_with?("\n")
        raise "unfaithful git fake for `#{key}`: real git stdout ends with a newline — " \
              'append "\n" to the fake response'
      end
      response
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
      git_responses['rev-parse HEAD'] = "bbb222\n"
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
      git_responses['rev-parse HEAD'] = "aaa111\n"
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
      git_responses['rev-parse HEAD'] = "ccc333\n"
      git_responses['-c core.quotepath=false diff --no-renames --relative --name-only aaa111 ccc333'] =
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
      git_responses['rev-parse HEAD'] = "ccc333\n"
      git_responses['-c core.quotepath=false diff --no-renames --relative --name-only aaa111 ccc333'] =
        "README.md\ndocs/guide.md\n"
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
      git_responses['rev-parse HEAD'] = "ccc333\n"
      git_responses['-c core.quotepath=false diff --no-renames --relative --name-only ddd444 ccc333'] = nil
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
      git_responses['rev-parse HEAD'] = "ccc333\n"
      git_responses['-c core.quotepath=false diff --no-renames --relative --name-only aaa111 ccc333'] =
        "app/models/felled.rb\n"
      allow(extractor).to receive(:removed_unit_ids).and_return(%w[Felled])
      write_index!
      write_cursor!('aaa111')

      result = sync.run

      expect(extractor).to have_received(:extract_changed).with(%w[app/models/felled.rb])
      expect(result.removed_units).to eq(%w[Felled])
    end
  end

  describe 'full-extraction-only changes (schema / routes / Gemfile.lock)' do
    it 'reports them via full_extract_pending instead of feeding them to extract_changed' do
      git_responses['rev-parse HEAD'] = "ccc333\n"
      git_responses['-c core.quotepath=false diff --no-renames --relative --name-only aaa111 ccc333'] =
        "db/schema.rb\nconfig/routes.rb\nGemfile.lock\napp/models/post.rb\n"
      write_index!
      write_cursor!('aaa111')

      result = sync.run

      expect(extractor).to have_received(:extract_changed).with(%w[app/models/post.rb])
      expect(result.full_extract_pending).to eq(%w[db/schema.rb config/routes.rb Gemfile.lock])
    end

    it 'covers db/structure.sql for schema_format = :sql apps' do
      git_responses['rev-parse HEAD'] = "ccc333\n"
      git_responses['-c core.quotepath=false diff --no-renames --relative --name-only aaa111 ccc333'] =
        "db/structure.sql\n"
      write_index!
      write_cursor!('aaa111')

      result = sync.run

      expect(extractor).not_to have_received(:extract_changed)
      expect(result.full_extract_pending).to eq(%w[db/structure.sql])
      expect(cursor_on_disk).to eq('ccc333')
    end

    it 'advances the cursor without extracting when only full-extraction files changed' do
      git_responses['rev-parse HEAD'] = "ccc333\n"
      git_responses['-c core.quotepath=false diff --no-renames --relative --name-only aaa111 ccc333'] =
        "config/routes.rb\n"
      write_index!
      write_cursor!('aaa111')

      result = sync.run

      expect(extractor).not_to have_received(:extract_changed)
      expect(result.mode).to eq(:up_to_date)
      expect(result.full_extract_pending).to eq(%w[config/routes.rb])
      expect(cursor_on_disk).to eq('ccc333')
    end
  end

  describe 'cursor file round-trip' do
    it 'is byte-identical across consecutive runs (no accumulating newlines)' do
      git_responses['rev-parse HEAD'] = "aaa111\n"
      write_index!

      sync.run # first run writes the cursor
      cursor_path = File.join(output_dir, described_class::CURSOR_FILENAME)
      first_bytes = File.binread(cursor_path)
      expect(first_bytes).to eq("aaa111\n")

      result = sync.run # cursor now at HEAD — must be a no-op
      expect(result.mode).to eq(:up_to_date)
      expect(File.binread(cursor_path)).to eq(first_bytes)
    end
  end

  # ── against a real git repository ─────────────────────────────────────
  #
  # The fake-git specs above stub the subprocess; this block exercises the
  # REAL Open3 path against a throwaway repo, pinning the actual git
  # contract (trailing-newline stdout, diff argv resolution, quotepath).
  # The newline bug this guards against: run_git returned raw stdout, so
  # HEAD carried "\n", cursor==head never matched, and every sync after the
  # first full-extracted as :diff_failed.
  describe 'against a real git repository' do
    def real_git!(*args)
      out, err, status = Open3.capture3('git', '-C', tmpdir, *args)
      raise "git #{args.join(' ')} failed: #{err}" unless status.success?

      out.chomp
    end

    def commit_all!(message)
      real_git!('add', '-A')
      real_git!('-c', 'user.name=woods', '-c', 'user.email=woods@example.com',
                'commit', '-m', message, '--no-gpg-sign')
    end

    let(:real_sync) { described_class.new(output_dir: output_dir, root: root, extractor: extractor) }

    before do
      require 'open3'
      real_git!('init', '-q')
      FileUtils.mkdir_p(File.join(tmpdir, 'app/models'))
      File.write(File.join(tmpdir, 'app/models/post.rb'), "class Post; end\n")
      commit_all!('initial')
      write_index!
    end

    it 'is up to date on the run after the first — the cursor matches real HEAD' do
      first = real_sync.run
      expect(first.mode).to eq(:full)
      expect(first.cursor).to eq(real_git!('rev-parse', 'HEAD'))

      second = real_sync.run
      expect(second.mode).to eq(:up_to_date)
      expect(extractor).to have_received(:extract_all).once
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'keeps the cursor file byte-identical across runs' do
      real_sync.run
      cursor_path = File.join(output_dir, described_class::CURSOR_FILENAME)
      first_bytes = File.binread(cursor_path)
      expect(first_bytes).to eq("#{real_git!('rev-parse', 'HEAD')}\n")

      real_sync.run
      expect(File.binread(cursor_path)).to eq(first_bytes)
    end

    it 'extracts exactly the committed change on the next run, then settles' do
      real_sync.run

      File.write(File.join(tmpdir, 'app/models/comment.rb'), "class Comment; end\n")
      commit_all!('add comment')

      result = real_sync.run
      expect(result.mode).to eq(:incremental)
      expect(result.changed_files).to eq(%w[app/models/comment.rb])
      expect(extractor).to have_received(:extract_changed).with(%w[app/models/comment.rb])

      expect(real_sync.run.mode).to eq(:up_to_date)
    end

    it 'reports deleted files in the diff so their units get removed' do
      real_sync.run

      FileUtils.rm(File.join(tmpdir, 'app/models/post.rb'))
      commit_all!('fell post')

      result = real_sync.run
      expect(result.mode).to eq(:incremental)
      expect(result.changed_files).to eq(%w[app/models/post.rb])
    end

    it 'emits non-ASCII paths verbatim (core.quotepath disabled)' do
      real_sync.run

      File.write(File.join(tmpdir, 'app/models/café.rb'), "class Café; end\n")
      commit_all!('add café')

      result = real_sync.run
      expect(result.changed_files).to eq(%w[app/models/café.rb])
    end

    it 'reports BOTH sides of a rename so the old unit gets removed (--no-renames)' do
      # A file large enough that `git mv` + a one-line edit stays above the
      # ~50% similarity threshold — the case where rename detection collapses
      # --name-only output to just the new path and the delete half vanishes.
      body = "class Invoice\n#{(1..40).map { |i| "  def line_#{i} = #{i}" }.join("\n")}\nend\n"
      File.write(File.join(tmpdir, 'app/models/invoice.rb'), body)
      commit_all!('add invoice')
      real_sync.run

      FileUtils.mv(File.join(tmpdir, 'app/models/invoice.rb'),
                   File.join(tmpdir, 'app/models/receipt.rb'))
      File.write(File.join(tmpdir, 'app/models/receipt.rb'),
                 body.sub('class Invoice', 'class Receipt'))
      commit_all!('rename invoice to receipt')

      result = real_sync.run
      expect(result.changed_files).to contain_exactly(
        'app/models/invoice.rb', 'app/models/receipt.rb'
      )
    end
  end

  # ── monorepo layout: Rails app in a repo subdirectory ─────────────────
  #
  # Without --relative, `git -C <rails-root> diff --name-only` emits
  # repo-root-relative paths (backend/app/models/…) that never match the
  # Rails.root-anchored RELEVANT_PATTERNS — every sync silently no-opped
  # as up-to-date.
  describe 'against a real git repository (monorepo layout)' do
    let(:repo_root) { tmpdir }
    let(:rails_root) { Pathname.new(File.join(tmpdir, 'backend')) }
    let(:mono_output_dir) { File.join(rails_root, 'tmp/woods') }
    let(:mono_sync) { described_class.new(output_dir: mono_output_dir, root: rails_root, extractor: extractor) }

    def repo_git!(*args)
      out, err, status = Open3.capture3('git', '-C', repo_root, *args)
      raise "git #{args.join(' ')} failed: #{err}" unless status.success?

      out.chomp
    end

    before do
      require 'open3'
      repo_git!('init', '-q')
      FileUtils.mkdir_p(File.join(rails_root, 'app/models'))
      File.write(File.join(rails_root, 'app/models/post.rb'), "class Post; end\n")
      repo_git!('add', '-A')
      repo_git!('-c', 'user.name=woods', '-c', 'user.email=woods@example.com',
                'commit', '-m', 'initial', '--no-gpg-sign')
      FileUtils.mkdir_p(mono_output_dir)
      File.write(File.join(mono_output_dir, 'manifest.json'), '{"total_units": 1, "counts": {"models": 1}}')
    end

    it 'emits Rails.root-relative paths so relevance filtering works (--relative)' do
      mono_sync.run # first run: full, writes cursor

      File.write(File.join(rails_root, 'app/models/comment.rb'), "class Comment; end\n")
      repo_git!('add', '-A')
      repo_git!('-c', 'user.name=woods', '-c', 'user.email=woods@example.com',
                'commit', '-m', 'add comment', '--no-gpg-sign')

      result = mono_sync.run
      expect(result.mode).to eq(:incremental)
      expect(result.changed_files).to eq(%w[app/models/comment.rb])
      expect(extractor).to have_received(:extract_changed).with(%w[app/models/comment.rb])
    end
  end
end
