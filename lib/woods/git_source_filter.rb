# frozen_string_literal: true

require 'set'
require_relative 'git_provenance'

module Woods
  # Filters source discovery using the extracted application's Git index and
  # ignore rules, independently of Woods' own checkout and history enrichment.
  #
  # The index and the ignore rules for tracked files are read once per filter
  # (two git processes), not once per path: a source check or a dispatch asks
  # about every configuration path, and a process per path used to take a
  # quick freshness check's whole time budget. Only an untracked path, which
  # Git cannot list cheaply, is still asked about on its own, once.
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

      # Forget every remembered root (specs).
      # @return [void]
      def reset_availability!
        @available_mutex.synchronize { @available_roots.clear }
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

      relative = path.to_s.delete_prefix("#{@root}/")
      index = git_index
      return per_path_reason(relative) unless index

      if index.fetch(:tracked).include?(relative)
        index.fetch(:ignored).include?(relative) ? 'git_ignored' : nil
      else
        @untracked[relative] ||= untracked_reason(relative)
      end
    end

    private

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
      succeeds?('check-ignore', '--quiet', '--no-index', '--', relative) ? 'git_ignored' : 'untracked'
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
