# frozen_string_literal: true

require 'open3'
require 'set'
require_relative 'git_provenance'
require_relative 'git_command'

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
      return @prefetched.delete(path) if @prefetched&.key?(path)
      return unless available?

      relative = relative(path)
      return 'git_ignored' if succeeds?('check-ignore', '--quiet', '--no-index', '--', relative)
      return 'untracked' unless tracked?(relative)

      nil
    end

    # {#skip_reason} for many paths with two git processes in all, rather than
    # two per path. Each process starts the size of the calling Ruby process,
    # so on a large application a per-path query costs tens of milliseconds.
    #
    # A path the batch finds neither ignored nor in the index is confirmed with
    # the single-path query, so every answer is the one {#skip_reason} would
    # give: the batch only ever shortens the work. A batch query that fails
    # falls back to one query per path.
    #
    # @param paths [Enumerable<String>] absolute or root-relative source paths
    # @return [Hash{String => String, nil}] each given path's skip reason
    def skip_reasons(paths)
      paths = paths.to_a.uniq
      return paths.to_h { |path| [path, nil] } unless available?

      relatives = paths.to_h { |path| [path, relative(path)] }
      verdicts = batch_verdicts(relatives.values.uniq)
      return paths.to_h { |path| [path, skip_reason(path)] } unless verdicts

      paths.to_h { |path| [path, batch_reason(relatives.fetch(path), *verdicts)] }
    end

    # Answer the next {#skip_reason} for each path from one batch.
    #
    # Each answer is used once and then forgotten, so a caller that walks the
    # paths it prefetched asks git about each as often as before, only sooner;
    # a later query for the same path asks git again. Call
    # {#discard_prefetched} when the walk ends so an answer it never used
    # cannot outlive it.
    #
    # @param paths [Enumerable<String>] the exact strings later passed to {#skip_reason}
    # @return [void]
    def prefetch(paths)
      paths = paths.to_a
      return if paths.empty?

      (@prefetched ||= {}).merge!(skip_reasons(paths))
    end

    # Forget every unused prefetched answer.
    #
    # @return [void]
    def discard_prefetched
      @prefetched = nil
    end

    private

    BATCH_SIZE = 500
    private_constant :BATCH_SIZE

    def relative(path)
      path.to_s.delete_prefix("#{@root}/")
    end

    def succeeds?(*args)
      _out, _err, status = Open3.capture3(*GitCommand.argv(@root, *args))
      status.success?
    end

    # @return [Array(Set, Set), nil] the ignored and the indexed paths, nil when a query failed
    def batch_verdicts(relatives)
      ignored = ignored_paths(relatives)
      indexed = ignored && indexed_paths(relatives)
      [ignored, indexed] if indexed
    end

    # @return [String, nil] the batch's verdict, confirming an untracked one
    def batch_reason(relative, ignored, indexed)
      return 'git_ignored' if ignored.include?(relative)
      return nil if indexed.include?(relative) || tracked?(relative)

      'untracked'
    end

    def tracked?(relative)
      succeeds?('--literal-pathspecs', 'ls-files', '--error-unmatch', '--', relative)
    end

    # check-ignore exits 0 when some path is ignored and 1 when none is.
    #
    # @return [Set<String>, nil] the ignored paths, nil when the query failed
    def ignored_paths(relatives)
      out, _err, status = Open3.capture3(*GitCommand.argv(@root, 'check-ignore', '--no-index', '--stdin', '-z'),
                                         stdin_data: relatives.map { |path| "#{path}\0" }.join, binmode: true)
      return unless status.success? || status.exitstatus == 1

      nul_separated(out)
    rescue SystemCallError, IOError
      nil
    end

    # @return [Set<String>, nil] the given paths the index holds, nil when a query failed
    def indexed_paths(relatives)
      relatives.each_slice(BATCH_SIZE).with_object(Set.new) do |slice, indexed|
        out, _err, status = Open3.capture3(*GitCommand.argv(@root, '--literal-pathspecs', 'ls-files', '-z', '--',
                                                            *slice), binmode: true)
        return nil unless status.success?

        indexed.merge(nul_separated(out))
      end
    rescue SystemCallError, IOError
      nil
    end

    def nul_separated(out)
      out.force_encoding(Encoding::UTF_8).split("\0").to_set
    end
  end
end
