# frozen_string_literal: true

require_relative 'git_provenance'

module Woods
  # Filters source discovery using the extracted application's Git index and
  # ignore rules, independently of Woods' own checkout and history enrichment.
  class GitSourceFilter
    # @param root [String, Pathname, nil] application root; nil means unavailable
    def initialize(root:)
      @root = root&.to_s
    end

    # @return [Boolean] whether the source Git filter can run
    def available?
      return false if @root.to_s.empty? || !File.exist?(File.join(@root, '.git'))

      (@provenance ||= GitProvenance.new(root: @root)).source_filter_available?
    end

    # @param path [String] absolute or root-relative source path
    # @return [String, nil] git_ignored, untracked, or nil when allowed/unavailable
    def skip_reason(path)
      return unless available?

      relative = path.to_s.delete_prefix("#{@root}/")
      return 'git_ignored' if succeeds?('check-ignore', '--quiet', '--no-index', '--', relative)
      return 'untracked' unless succeeds?('--literal-pathspecs', 'ls-files', '--error-unmatch', '--', relative)

      nil
    end

    private

    def succeeds?(*args)
      _out, _err, status = Open3.capture3(*GitCommand.argv(@root, *args))
      status.success?
    end
  end
end
