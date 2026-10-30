# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'pathname'
require_relative 'atomic_file'
require_relative 'generation'
require_relative 'git_command'
require_relative 'git_provenance'
require_relative 'payload_store'
require_relative 'rake_helpers'
require_relative 'source_inputs/private_key'
require_relative 'source_path_encoding'
require_relative 'worktree_seed/changes'
require_relative 'worktree_seed/verification'

module Woods
  # Gives a new worktree an index by copying another checkout's published
  # generation and updating it with an incremental run, instead of a cold full
  # extraction.
  #
  # The seed is built beside the final index directory (`<output>.seed-<pid>`),
  # the incremental run happens there, and only the finished result is moved
  # into place. `generation.json` is renamed last, so a reader of the final
  # directory sees nothing until the seeded index is complete, and a crash at
  # any earlier point leaves no published generation behind.
  #
  # The seed is used only when it can be shown to describe a commit of this
  # repository exactly. Otherwise the run falls back to a full extraction and
  # says why:
  #
  # - the seed was written by another Woods version, or is not incremental-ready
  # - it records no usable commit, or this repository does not have that commit
  # - its checkout has moved off that commit, has uncommitted changes, or no
  #   longer matches the source it indexed
  # - it has no source identity key to carry over
  # - a changed path needs a fresh Rails boot (`Gemfile.lock`, initializers,
  #   `db/schema.rb`) or a git diff cannot be taken
  # - the extraction configuration differs, or the incremental run raises
  #
  # What is rewritten for the new checkout: `git_branch` and `git_sha` in the
  # manifest, and the recorded source root and generation number in
  # `source_inputs.json`. The generation number restarts at 1, as it is local to
  # an index. Embedding dumps and other operational state are not copied.
  #
  # The change set is `git diff <seed sha>` against the working tree (committed
  # and uncommitted tracked changes) plus untracked files. Ignored files are not
  # part of it.
  class WorktreeSeed
    # @!attribute [r] mode
    #   @return [Symbol] `:seeded`, `:full` (fell back), or `:skipped`
    # @!attribute [r] reason
    #   @return [String, nil] why the run did not seed, for `:full` and `:skipped`
    # @!attribute [r] changed
    #   @return [Array<String>, nil] paths the incremental run was given
    Result = Struct.new(:mode, :reason, :changed, keyword_init: true)

    # @param source_dir [String, Pathname] index directory of the checkout to seed from
    # @param output_dir [String, Pathname] index directory of the new worktree
    # @param root [String, Pathname] the new worktree's application root
    # @param extractor [Class] extractor class, injectable for specs
    def initialize(source_dir:, output_dir:, root:, extractor: nil)
      @source = Pathname.new(source_dir.to_s)
      @output = Pathname.new(output_dir.to_s)
      @root = Pathname.new(root.to_s)
      @extractor_class = extractor
    end

    # @return [Result]
    def call
      return Result.new(mode: :skipped, reason: "#{@output} already has a published index") if published?(@output)

      seeded = seed
      seeded.is_a?(Result) ? seeded : full_extraction(seeded)
    end

    private

    def extractor_class
      @extractor_class ||= begin
        require_relative 'extractor'
        Woods::Extractor
      end
    end

    def published?(dir)
      Generation.new(output_dir: dir).current.number.positive?
    end

    # @return [Result, String] the seeded result, or the reason to fall back
    def seed
      raise Unverifiable, 'the seed is the target index' if @source.expand_path == @output.expand_path

      baseline = Verification.new(source: @source, root: @root).call
      staging = Pathname.new("#{@output}.seed-#{Process.pid}")
      begin
        build_staging(staging, baseline)
        changed = Changes.new(root: @root, index: staging).since(baseline.fetch('git_sha'))
        run_incremental(staging, changed)
        promote(staging)
        Result.new(mode: :seeded, changed: changed)
      ensure
        FileUtils.rm_rf(staging)
      end
    rescue Unverifiable, Woods::ExtractionError, SystemCallError, IOError, JSON::ParserError => e
      e.message
    end

    def full_extraction(reason)
      extractor = extractor_class.new(output_dir: @output)
      extractor.extract_all
      extractor.raise_on_publication_failure!
      Result.new(mode: :full, reason: reason)
    end

    # ── Staging ────────────────────────────────────────────────────────────

    def build_staging(staging, _baseline)
      FileUtils.rm_rf(staging)
      payload = staging.join(PayloadStore.name_for(1))
      FileUtils.mkdir_p(payload.dirname)
      FileUtils.cp_r(Generation.new(output_dir: @source).payload_dir.to_s, payload.to_s)
      install_key(staging)
      rewrite_provenance(payload)
      Generation.new(output_dir: staging).bump!(reason: 'seed', payload: PayloadStore.name_for(1))
    end

    def install_key(dir)
      key = File.binread(@source.join(SourceInputs::PrivateKey::FILE_NAME))
      File.open(dir.join(SourceInputs::PrivateKey::FILE_NAME), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.binmode.write(key)
      end
    end

    # The manifest and the source evidence describe the checkout they were
    # written in. Rewrite exactly what names it.
    def rewrite_provenance(payload)
      provenance = GitProvenance.new(root: @root).to_h
      update_json(payload.join('manifest.json')) do |manifest|
        manifest.merge('git_sha' => provenance[:git_sha], 'git_branch' => provenance[:git_branch])
      end
      update_json(payload.join('source_inputs.json')) do |inputs|
        inputs.merge('root' => SourcePathEncoding.expand(@root), 'generation' => 1)
      end
    end

    def update_json(path)
      original = AtomicFile.read(path)
      updated = yield JSON.parse(original)
      AtomicFile.write(path, original.include?("\n") ? JSON.pretty_generate(updated) : JSON.generate(updated))
    end

    def run_incremental(staging, changed)
      extractor = extractor_class.new(output_dir: staging)
      extractor.extract_changed(changed)
      extractor.raise_on_publication_failure!
    rescue Woods::ExtractionConfigChanged => e
      raise Unverifiable, e.message
    end

    # ── Publication ────────────────────────────────────────────────────────

    # Move the finished index into the final directory. The key and payloads go
    # first; `generation.json` is renamed last and is the only thing that makes
    # the index visible.
    def promote(staging)
      FileUtils.mkdir_p(@output)
      payloads = @output.join(PayloadStore::DIRNAME)
      FileUtils.rm_rf(payloads)
      FileUtils.mv(staging.join(SourceInputs::PrivateKey::FILE_NAME).to_s, @output.join(SourceInputs::PrivateKey::FILE_NAME).to_s,
                   force: true)
      FileUtils.mv(staging.join(PayloadStore::DIRNAME).to_s, payloads.to_s)
      File.rename(staging.join(Generation::FILENAME), @output.join(Generation::FILENAME))
    end
  end
end
