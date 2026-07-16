# frozen_string_literal: true

require 'open3'
require 'pathname'

require_relative 'atomic_file'
require_relative 'extractor'

module Woods
  # Cursor-based incremental sync — the shared entry point behind
  # `rake woods:sync`.
  #
  # Encapsulates the loop per-merge consumers (CI pipelines, local dev hooks)
  # used to hand-roll around `woods:incremental`:
  #
  # 1. Remember the SHA of the last successful extraction in
  #    +output_dir/.sync_head+.
  # 2. +git diff --name-only <cursor> HEAD+ to find what changed.
  # 3. Run an incremental extraction over the relevant changed files
  #    (deleted files included — their units are removed, see B-065).
  # 4. Fall back to a full extraction when there's no index, no cursor, or
  #    the cursor SHA can't be diffed (force push, shallow clone, gc).
  # 5. Advance the cursor only after the extraction succeeded.
  #
  # The cursor is deliberately owned by the side running the sync — which
  # has working git by construction — and NOT derived from
  # +manifest.git_sha+: that field is correctly +"unknown"+ when extraction
  # runs in a container where a linked worktree's gitdir isn't mounted
  # (the #137 provenance design), so it can't serve as a diff base.
  #
  # @example One entry point for CI and local dev
  #   Woods::Sync.new.run
  #   # => #<Result mode=:incremental changed_files=[...] affected=[...]>
  class Sync
    # Cursor file recording the SHA of the last successful sync, stored
    # alongside the index it describes.
    CURSOR_FILENAME = '.sync_head'

    # Extraction-relevant directories (matched as `^<dir>/`). Workers are
    # Sidekiq; blueprinters are serializers; use_cases/interactors/
    # operations/commands are the service-discovery roots.
    RELEVANT_DIRS = %w[
      app/models app/controllers app/services app/components
      app/views/components app/interactors app/operations app/commands
      app/use_cases app/jobs app/workers app/mailers app/graphql
      app/serializers app/decorators app/blueprinters db/migrate
    ].freeze

    # Relevant paths whose units can only be refreshed by a FULL extraction:
    # routes/schema map to file-less unit types the incremental path skips,
    # and Gemfile.lock signals a framework re-index (woods:extract_framework).
    # Feeding them to extract_changed would only produce misleading
    # unhandled-file warnings and phantom re-extracted counts — sync reports
    # them via Result#full_extract_pending instead.
    FULL_EXTRACT_ONLY_PATTERNS = [
      %r{^db/schema\.rb$},
      %r{^db/structure\.sql$}, # schema_format = :sql apps keep the schema here
      %r{^config/routes\.rb$},
      /^Gemfile\.lock$/
    ].freeze

    # Changed-file relevance filter shared with `rake woods:incremental` —
    # paths outside these patterns can't produce or affect extracted units,
    # so syncing them would only generate unhandled-file warnings. Beyond
    # the directory roots: Phlex views, plus the FULL_EXTRACT_ONLY_PATTERNS
    # trio (schema / routes / Gemfile.lock).
    RELEVANT_PATTERNS = (RELEVANT_DIRS.map { |dir| %r{^#{Regexp.escape(dir)}/} } +
      [%r{^app/views/.*\.rb$}] + FULL_EXTRACT_ONLY_PATTERNS).freeze

    # Outcome of a {#run}.
    #
    # @!attribute mode
    #   @return [Symbol] :full, :incremental, or :up_to_date
    # @!attribute reason
    #   @return [Symbol, nil] why a full extraction ran — :no_cursor,
    #     :no_index, :git_unavailable, or :diff_failed
    # @!attribute cursor
    #   @return [String, nil] the cursor after this run (HEAD on success)
    # @!attribute changed_files
    #   @return [Array<String>] relevant changed paths handed to extraction
    # @!attribute affected
    #   @return [Array<String>] re-extracted / newly added unit identifiers
    # @!attribute removed_units
    #   @return [Array<String>] units removed for deleted source files
    # @!attribute unhandled_files
    #   @return [Array<String>] changed files no unit type could be mapped to
    # @!attribute full_extract_pending
    #   @return [Array<String>] relevant changed files (schema / routes /
    #     Gemfile.lock) whose units only refresh on a full extraction
    Result = Struct.new(:mode, :reason, :cursor, :changed_files, :affected,
                        :removed_units, :unhandled_files, :full_extract_pending,
                        keyword_init: true)

    # @param output_dir [String, Pathname, nil] Extraction output directory
    #   (default: Rails.root/tmp/woods, or WOODS_OUTPUT via the rake task)
    # @param root [Pathname, nil] Repository root git runs against
    #   (default: Rails.root)
    # @param extractor [Woods::Extractor, nil] Injectable for tests
    # @param git [#call, nil] Injectable git runner for tests — receives the
    #   argv after `git -C <root>`, returns stdout on success or nil on failure
    def initialize(output_dir: nil, root: nil, extractor: nil, git: nil)
      @root = Pathname.new((root || Rails.root).to_s)
      @output_dir = Pathname.new((output_dir || Rails.root.join('tmp/woods')).to_s)
      @extractor = extractor
      @git = git
    end

    # Perform one sync step.
    #
    # @return [Result]
    # @raise [Woods::ExtractionError] propagated from extraction — the
    #   cursor is not advanced, so the next run retries the same range
    def run
      head = run_git('rev-parse', 'HEAD')
      return full_extract(reason: :git_unavailable, advance_to: nil) unless head

      cursor = read_cursor
      return full_extract(reason: :no_cursor, advance_to: head) unless cursor
      return full_extract(reason: :no_index, advance_to: head) unless index_present?

      return result(mode: :up_to_date, cursor: head) if cursor == head

      changed = changed_files_between(cursor, head)
      return full_extract(reason: :diff_failed, advance_to: head) if changed.nil?

      incremental_extract(changed, head)
    end

    private

    # Extract the relevant subset of +changed+ and advance the cursor.
    # An all-irrelevant diff just advances the cursor — nothing to extract.
    # Full-extraction-only paths are split out and reported, not extracted.
    def incremental_extract(changed, head)
      relevant = changed.select { |f| RELEVANT_PATTERNS.any? { |p| f.match?(p) } }
      full_only, extractable = relevant.partition do |f|
        FULL_EXTRACT_ONLY_PATTERNS.any? { |p| f.match?(p) }
      end

      if extractable.empty?
        write_cursor(head)
        return result(mode: :up_to_date, cursor: head, full_extract_pending: full_only)
      end

      affected = extractor.extract_changed(extractable)
      write_cursor(head)
      result(
        mode: :incremental, cursor: head, changed_files: extractable, affected: affected,
        removed_units: extractor.removed_unit_ids, unhandled_files: extractor.unhandled_changed_files,
        full_extract_pending: full_only
      )
    end

    def extractor
      @extractor ||= Woods::Extractor.new(output_dir: @output_dir)
    end

    def full_extract(reason:, advance_to:)
      extractor.extract_all
      write_cursor(advance_to) if advance_to
      result(mode: :full, reason: reason, cursor: advance_to)
    end

    # Result with empty-collection defaults for the no-work fields.
    def result(**fields)
      Result.new(changed_files: [], affected: [], removed_units: [],
                 unhandled_files: [], full_extract_pending: [], **fields)
    end

    # @return [Array<String>, nil] Changed paths, or nil when the diff can't
    #   be resolved (unknown cursor SHA — force push, shallow clone, gc)
    #
    # Three flags reconcile git's porcelain defaults with what extraction
    # needs (each hides changes without them):
    # - `-c core.quotepath=false`: emit non-ASCII paths verbatim — default
    #   quotepath returns `"app/models/caf\303\251.rb"` (quoted,
    #   octal-escaped), matching neither the file map nor the filesystem.
    # - `--no-renames`: rename detection is ON by default and collapses a
    #   `git mv` to just the NEW path in --name-only output — the old path
    #   never reached extract_changed, so the B-065 ghost-removal was dead
    #   code for exactly the rename case it exists for.
    # - `--relative`: diff paths are repo-root-relative; in a monorepo
    #   (Rails app in a subdirectory) nothing matched the Rails.root-anchored
    #   RELEVANT_PATTERNS and every sync silently no-opped as up-to-date.
    #   --relative scopes and rewrites paths to @root.
    def changed_files_between(cursor, head)
      output = run_git('-c', 'core.quotepath=false', 'diff',
                       '--no-renames', '--relative', '--name-only', cursor, head)
      return nil unless output

      output.lines.map(&:strip).reject(&:empty?)
    end

    def cursor_path
      @output_dir.join(CURSOR_FILENAME)
    end

    def read_cursor
      sha = cursor_path.read.strip if cursor_path.file?
      sha unless sha.nil? || sha.empty?
    end

    def write_cursor(sha)
      AtomicFile.write(cursor_path, "#{sha}\n")
    end

    def index_present?
      @output_dir.join('manifest.json').file?
    end

    # Run git against the repository root; nil on any failure. Open3 (not
    # backticks) per the shell-injection convention, and `-C @root` so the
    # result is cwd-independent (mirrors GitProvenance). Output is normalized
    # at this boundary for the injected test double too, so a faithful fake
    # (returning "sha\n" like the real subprocess) and real git behave
    # identically.
    def run_git(*args)
      output =
        if @git
          @git.call(*args)
        else
          stdout, _err, status = Open3.capture3('git', '-C', @root.to_s, *args)
          status.success? ? stdout : nil
        end
      normalize_git_output(output)
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    # Reconcile raw subprocess stdout with what callers assume:
    # - chomp git's trailing newline — a newline-bearing HEAD sha once
    #   defeated the up-to-date check and corrupted the diff argv, so every
    #   sync after the first full-extracted as :diff_failed;
    # - retag as UTF-8 and scrub — under a POSIX/C locale stdout arrives
    #   tagged US-ASCII, and a UTF-8 path raises Encoding::CompatibilityError
    #   in String#strip downstream (dup: fakes may hand us frozen literals).
    def normalize_git_output(output)
      return nil if output.nil?

      output.dup.force_encoding(Encoding::UTF_8).scrub.chomp
    end
  end
end
