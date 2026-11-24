# frozen_string_literal: true

require 'set'

module Woods
  # The installed git's version, as `git --version` reports it, and the
  # notice for a git too old for the history walk.
  #
  # {GitLog} compares merge diffs against the first parent with
  # `--diff-merges=first-parent`, which Git 2.31 added. An older git rejects
  # it (`fatal: unknown value for --diff-merges: first-parent`), so no walk
  # can succeed: per-unit git facts and `git_commits.json` are skipped, and
  # the run says why once, where the person running it sees it.
  module GitVersion
    # The first git whose `git log` accepts `--diff-merges=first-parent`.
    MINIMUM = Gem::Version.new('2.31.0')

    # The published {GitEnrichmentSummary} reason for a git below {MINIMUM}.
    REASON = 'git_too_old'

    ANSWER = /\Agit version (\d+)\.(\d+)(?:\.(\d+))?/

    @announced = Set.new
    @lock = Mutex.new

    module_function

    # @param answer [String, nil] the output of `git --version`
    # @return [Gem::Version, nil] major.minor.patch, nil when the answer is not
    #   a version (vendor and platform suffixes such as `(Apple Git-145)` or
    #   `.windows.1` are ignored)
    def parse(answer)
      match = answer.to_s.b.match(ANSWER)
      match && Gem::Version.new(match.captures.map { |part| Integer(part || '0', 10) }.join('.'))
    end

    # @param version [Gem::Version, nil]
    # @return [Boolean] true only for a known version below {MINIMUM}; an
    #   unknown version proceeds as before
    def too_old?(version)
      !version.nil? && version < MINIMUM
    end

    # @param version [Gem::Version]
    # @return [String] one line naming the version found and the version needed
    def notice(version)
      "[Woods] Git #{version} is older than #{MINIMUM.segments.first(2).join('.')}, which git enrichment " \
        'and git_commits.json need; extraction continues without them.'
    end

    # Log the {notice} on every run, and print it on stderr once per process:
    # a resident watcher runs many extractions and says it the first time.
    #
    # @param version [Gem::Version]
    # @param logger [#warn]
    # @return [void]
    def announce(version, logger:)
      line = notice(version)
      logger.warn(line)
      first = @lock.synchronize { @announced.add?(line) }
      warn(line) if first
    end

    # Forget which notices this process printed. For specs.
    #
    # @return [void]
    def reset_announcements!
      @lock.synchronize { @announced.clear }
    end
  end
end
