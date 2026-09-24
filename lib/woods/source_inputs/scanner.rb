# frozen_string_literal: true

require 'find'
require 'openssl'
require 'woods/source_inputs/private_key'
require 'woods/source_inputs/scopes'
require 'woods/watch/watcher'

module Woods
  module SourceInputs
    # Unlike the watcher's best-effort walk, every incomplete read is evidence
    # against claiming complete source coverage. No Rails application is booted.
    class Scanner # rubocop:disable Metrics/ClassLength -- one bounded traversal owns its counters and read checks
      DEFAULT_LIMITS = { max_files: 50_000, max_bytes: 128 * 1024 * 1024, max_seconds: 10.0 }.freeze
      class BudgetExceeded < StandardError; end

      attr_reader :root, :scopes

      def initialize(root:, output_dir:, key:, scopes: Scopes.new, **limits)
        @root = SourcePathEncoding.expand(root)
        @output_dir = SourcePathEncoding.expand(output_dir)
        @key = key
        @scopes = scopes
        @limits = DEFAULT_LIMITS.merge(limits)
        return if @limits.values.all? { |value| value.is_a?(Numeric) && value.finite? && value.positive? }

        raise ArgumentError, 'source scan limits must be finite and positive'
      end

      def call
        @captured_at = Time.now.to_f
        @started = monotonic
        @files = {}
        @scope_paths = {}
        @errors = []
        @bytes = 0
        @visited = 0
        walk
        result
      rescue BudgetExceeded => e
        error(e.message)
        result
      rescue SystemCallError, IOError
        error('source_tree_unavailable')
        result
      rescue EncodingError, SourcePathEncoding::Invalid
        error('undecodable_source_path')
        result
      end

      private

      def walk
        raise Errno::ENOENT, @root unless File.directory?(@root)

        @resolved_root = SourcePathEncoding.utf8!(File.realpath(@root))
        Find.find(@root, ignore_error: false) do |path|
          next if path == @root

          check_budget!
          path = decoded_entry(path)
          relative = path.delete_prefix("#{@root}/")
          if ignored_directory?(path, relative)
            Find.prune if File.directory?(path)
            next
          end
          stat = File.lstat(path)
          next if stat.directory?

          @visited += 1
          check_budget!
          visit(path, relative, stat)
        end
      end

      def decoded_entry(path)
        decoded = SourcePathEncoding.utf8(path)
        return decoded if decoded

        @visited += 1
        check_budget!
        relative = path.b.delete_prefix("#{@root}/".b)
        error('undecodable_source_path', SourcePathEncoding.diagnostic(relative))
        Find.prune
      end

      def ignored_directory?(path, relative)
        return true if path == @output_dir || path.start_with?("#{@output_dir}/")
        return false if declared_path?(relative)

        Watch::TreeScan.hidden?(relative) ||
          Watch::TreeScan.ignored?(relative, Watch::Watcher::DEFAULT_IGNORED_DIRECTORIES)
      end

      def declared_path?(relative)
        @scopes.extra_roots.any? do |root|
          relative == root || relative.start_with?("#{root}/") || root.start_with?("#{relative}/")
        end
      end

      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      # Refuse opaque directories, external paths and unreadable inputs separately.
      def visit(path, relative, stat)
        if stat.symlink? && File.directory?(path)
          error('unverified_symlink_directory', relative)
          return
        end
        consumers = @scopes.for_path(relative)
        return if consumers.empty?

        real = SourcePathEncoding.utf8!(File.realpath(path))
        unless real.start_with?("#{@resolved_root}/")
          error('external_source_path', relative)
          return
        end
        identity = read_identity(path, real, stamp(File.stat(real)))
        return unless identity

        @files[relative] = identity
        consumers.each { |scope| (@scope_paths[scope] ||= []) << relative }
      rescue SystemCallError, IOError
        error('source_file_unreadable', relative)
      rescue EncodingError, SourcePathEncoding::Invalid
        error('undecodable_source_path', SourcePathEncoding.diagnostic(relative))
      end

      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      def read_identity(path, resolved, expected) # rubocop:disable Metrics/CyclomaticComplexity -- stable descriptor and original resolution checks
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(resolved, flags) do |file|
          before = stamp(file.stat)
          unless before == expected && resolved_path(path) == resolved
            error('source_changed_during_read', path.delete_prefix("#{@root}/"))
            return nil
          end
          unless file.stat.file?
            error('nonregular_source', path.delete_prefix("#{@root}/"))
            return nil
          end
          identity = hash_stream(file)
          unless before == stamp(file.stat) && before == stamp(File.stat(resolved)) && resolved_path(path) == resolved
            error('source_changed_during_read', path.delete_prefix("#{@root}/"))
            return nil
          end
          identity
        end
      end

      def resolved_path(path)
        SourcePathEncoding.utf8!(File.realpath(path))
      end

      def hash_stream(file)
        digest = OpenSSL::HMAC.new(@key.bytes, OpenSSL::Digest.new('SHA256'))
        while (chunk = file.read(16_384))
          @bytes += chunk.bytesize
          check_budget!
          digest.update(chunk)
        end
        digest.hexdigest
      end

      def stamp(stat)
        [stat.dev, stat.ino, stat.size, stat.mtime.to_r, stat.ctime.to_r]
      end

      def check_budget!
        raise BudgetExceeded, 'scan_time_budget' if monotonic - @started > @limits[:max_seconds]
        raise BudgetExceeded, 'scan_file_budget' if @visited > @limits[:max_files]
        raise BudgetExceeded, 'scan_byte_budget' if @bytes > @limits[:max_bytes]
      end

      def error(reason, path = nil)
        @errors << { 'reason' => reason, 'path' => path }.compact if @errors.size < 20
      end

      def result
        { 'root' => @root, 'key_id' => @key.identifier, 'rules' => @scopes.fingerprint,
          'captured_at' => @captured_at,
          'extra_roots' => @scopes.extra_roots, 'files' => @files.sort.to_h,
          'scope_paths' => @scope_paths.transform_values(&:sort).sort.to_h,
          'errors' => @errors, 'complete' => @errors.empty?,
          'metrics' => { 'visited_files' => @visited, 'hashed_files' => @files.size,
                         'bytes' => @bytes, 'elapsed_ms' => ((monotonic - @started) * 1000).round(3) } }
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
