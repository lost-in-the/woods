# frozen_string_literal: true

require 'set'
require_relative 'git_provenance'
require_relative 'git_source_answers'

module Woods
  # Filters source discovery using the extracted application's Git index and
  # ignore rules, independently of Woods' own checkout and history enrichment.
  #
  # The index and the ignore rules for tracked files are read once per filter
  # (two git processes), not once per path: a source check or a dispatch asks
  # about every configuration path, and a process per path used to take a
  # quick freshness check's whole time budget. Only an untracked path, which
  # Git cannot list cheaply, is still asked about on its own, once.
  #
  # {#skip_reasons} answers many paths at once: the untracked ones go to Git
  # in one `check-ignore --stdin` call, and {GitSourceAnswers} keeps the
  # answers until one of Git's inputs ({GitIgnoreInputs}) changes, so the
  # skipped-files report of a no-op incremental cycle spawns no git (#721).
  class GitSourceFilter
    # @param root [String, Pathname, nil] application root; nil means unavailable
    def initialize(root:)
      @root = root&.to_s
      @untracked = {}
    end

    # Roots this process has found a usable Git work tree at. A positive
    # answer is kept for the process (filters are built per check); a
    # negative one is asked again, so Git appearing later is noticed.
    @available_roots = Set.new
    @available_mutex = Mutex.new

    class << self
      # @api private
      # @return [Boolean] whether +root+ was found usable before
      def known_available?(root)
        @available_mutex.synchronize { @available_roots.include?(root) }
      end

      # @api private
      # @return [void]
      def remember_available(root)
        @available_mutex.synchronize { @available_roots << root }
      end

      # Forget every remembered root and the answers kept for it (specs).
      # @return [void]
      def reset_availability!
        @available_mutex.synchronize { @available_roots.clear }
        GitSourceAnswers.forget!
      end
    end

    # @return [Boolean] whether the source Git filter can run
    def available?
      return false if @root.to_s.empty? || !File.exist?(File.join(@root, '.git'))
      return true if self.class.known_available?(@root)

      (@provenance ||= GitProvenance.new(root: @root)).source_filter_available?.tap do |usable|
        self.class.remember_available(@root) if usable
      end
    end

    # @param path [String] absolute or root-relative source path
    # @return [String, nil] git_ignored, untracked, or nil when allowed/unavailable
    def skip_reason(path)
      return unless available?

      relative = relative_path(path)
      index = git_index
      index ? indexed_reason(index, relative) : per_path_reason(relative)
    end

    # The {#skip_reason} of each path, in a constant number of git processes.
    # A later call for the same paths spawns none while Git's inputs keep
    # their fingerprint; a path spelled with `.` or `..` segments, or outside
    # the root, is asked about alone and leaves the answers unkept.
    #
    # @param paths [Enumerable<String>] absolute or root-relative source paths
    # @return [Hash{String => String, nil}] frozen; root-relative path => reason
    def skip_reasons(paths)
      relatives = paths.map { |path| relative_path(path) }.uniq.sort
      return relatives.to_h { |relative| [relative, nil] }.freeze unless available?

      GitSourceAnswers.answers(@root, relatives) { batch_reasons(relatives) }
    end

    private

    def relative_path(path)
      path.to_s.delete_prefix("#{@root}/")
    end

    # @return [Array(Hash, Boolean)] the reasons, and whether every git call answered
    def batch_reasons(relatives)
      index = git_index
      return [relatives.to_h { |relative| [relative, per_path_reason(relative)] }.freeze, false] unless index

      complete = checked_untracked?(relatives.reject { |relative| index.fetch(:tracked).include?(relative) })
      [relatives.to_h { |relative| [relative, indexed_reason(index, relative)] }.freeze, complete]
    end

    # Ask Git about every untracked plain path in one call and remember the
    # answers; false when that call failed, and each path is then asked alone.
    def checked_untracked?(untracked)
      batched = untracked.select { |relative| GitSourceAnswers.plain?(relative) }
      ignored = ignored_among(batched)
      return false unless ignored

      batched.each { |relative| @untracked[relative] = untracked_label(ignored.include?(relative)) }
      true
    end

    def indexed_reason(index, relative)
      if index.fetch(:tracked).include?(relative)
        index.fetch(:ignored).include?(relative) ? 'git_ignored' : nil
      else
        @untracked[relative] ||= untracked_reason(relative)
      end
    end

    # The paths among +relatives+ the ignore rules match, in one call.
    # check-ignore exits 1 when it matches none; nil when it fails.
    def ignored_among(relatives)
      return Set.new if relatives.empty?

      out, _err, status = Open3.capture3(*GitCommand.argv(@root, 'check-ignore', '--no-index', '--stdin', '-z'),
                                         stdin_data: relatives.map { |relative| "#{relative}\0" }.join, binmode: true)
      return unless [0, 1].include?(status.exitstatus)

      out.force_encoding(Encoding::UTF_8).split("\0").to_set
    rescue SystemCallError
      nil
    end

    # Tracked paths, and the tracked paths the ignore rules match (Git's
    # check-ignore --no-index answer for a tracked file), relative to the
    # root. Nil when either listing fails; each path is then asked alone.
    def git_index
      return @git_index if defined?(@git_index)

      tracked = list('ls-files', '-z')
      ignored = list('ls-files', '-z', '--cached', '--ignored', '--exclude-standard')
      @git_index = tracked && ignored ? { tracked: tracked, ignored: ignored } : nil
    end

    def list(*args)
      out, _err, status = Open3.capture3(*GitCommand.argv(@root, *args), binmode: true)
      return nil unless status.success?

      out.force_encoding(Encoding::UTF_8).split("\0").to_set
    rescue SystemCallError
      nil
    end

    def untracked_reason(relative)
      untracked_label(succeeds?('check-ignore', '--quiet', '--no-index', '--', relative))
    end

    def untracked_label(ignored)
      ignored ? 'git_ignored' : 'untracked'
    end

    def per_path_reason(relative)
      return 'git_ignored' if succeeds?('check-ignore', '--quiet', '--no-index', '--', relative)
      return 'untracked' unless succeeds?('--literal-pathspecs', 'ls-files', '--error-unmatch', '--', relative)

      nil
    end

    def succeeds?(*args)
      _out, _err, status = Open3.capture3(*GitCommand.argv(@root, *args))
      status.success?
    end
  end
end
