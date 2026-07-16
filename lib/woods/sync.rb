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

    # Changed-file relevance filter shared with `rake woods:incremental` —
    # paths outside these patterns can't produce or affect extracted units,
    # so syncing them would only generate unhandled-file warnings.
    RELEVANT_PATTERNS = [
      %r{^app/models/},
      %r{^app/controllers/},
      %r{^app/services/},
      %r{^app/components/},
      %r{^app/views/components/},
      %r{^app/views/.*\.rb$}, # Phlex views
      %r{^app/interactors/},
      %r{^app/operations/},
      %r{^app/commands/},
      %r{^app/use_cases/},
      %r{^app/jobs/},
      %r{^app/workers/}, # Sidekiq workers
      %r{^app/mailers/},
      %r{^app/graphql/}, # GraphQL types/mutations/resolvers
      %r{^app/serializers/},
      %r{^app/decorators/},
      %r{^app/blueprinters/},
      %r{^db/migrate/},
      %r{^db/schema\.rb$}, # Schema changes affect model metadata
      %r{^config/routes\.rb$},
      /^Gemfile\.lock$/ # Dependency changes trigger framework re-index
    ].freeze

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
    Result = Struct.new(:mode, :reason, :cursor, :changed_files, :affected,
                        :removed_units, :unhandled_files, keyword_init: true)

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

      return up_to_date(head) if cursor == head

      changed = changed_files_between(cursor, head)
      return full_extract(reason: :diff_failed, advance_to: head) if changed.nil?

      incremental_extract(changed, head)
    end

    private

    # Extract the relevant subset of +changed+ and advance the cursor.
    # An all-irrelevant diff just advances the cursor — nothing to extract.
    def incremental_extract(changed, head)
      relevant = changed.select { |f| RELEVANT_PATTERNS.any? { |p| f.match?(p) } }
      if relevant.empty?
        write_cursor(head)
        return up_to_date(head)
      end

      affected = extractor.extract_changed(relevant)
      write_cursor(head)
      Result.new(
        mode: :incremental, cursor: head, changed_files: relevant, affected: affected,
        removed_units: extractor.removed_unit_ids, unhandled_files: extractor.unhandled_changed_files
      )
    end

    def extractor
      @extractor ||= Woods::Extractor.new(output_dir: @output_dir)
    end

    def full_extract(reason:, advance_to:)
      extractor.extract_all
      write_cursor(advance_to) if advance_to
      Result.new(mode: :full, reason: reason, cursor: advance_to,
                 changed_files: [], affected: [], removed_units: [], unhandled_files: [])
    end

    def up_to_date(head)
      Result.new(mode: :up_to_date, cursor: head, changed_files: [],
                 affected: [], removed_units: [], unhandled_files: [])
    end

    # @return [Array<String>, nil] Changed paths, or nil when the diff can't
    #   be resolved (unknown cursor SHA — force push, shallow clone, gc)
    def changed_files_between(cursor, head)
      output = run_git('diff', '--name-only', cursor, head)
      return nil unless output

      output.lines.map(&:strip).reject(&:empty?)
    end

    def cursor_path
      @output_dir.join(CURSOR_FILENAME)
    end

    def read_cursor
      return nil unless cursor_path.file?

      sha = cursor_path.read.strip
      sha.empty? ? nil : sha
    end

    def write_cursor(sha)
      AtomicFile.write(cursor_path, "#{sha}\n")
    end

    def index_present?
      @output_dir.join('manifest.json').file?
    end

    # Run git against the repository root; nil on any failure. Open3 (not
    # backticks) per the shell-injection convention, and `-C @root` so the
    # result is cwd-independent (mirrors GitProvenance).
    def run_git(*args)
      return @git.call(*args) if @git

      output, _err, status = Open3.capture3('git', '-C', @root.to_s, *args)
      status.success? ? output : nil
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end
  end
end
