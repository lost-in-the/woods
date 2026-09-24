# frozen_string_literal: true

require 'openssl'

module Woods
  module SourceInputs
    # Reads bytes only when their descriptor and captured keyed identity agree.
    # Paths may be captured internal file symlinks, but their resolution must
    # remain stable and inside the real application root throughout the read.
    class StableReader
      DEFAULT_LIMITS = { max_bytes: 8 * 1024 * 1024, max_seconds: 2.0 }.freeze

      class Error < StandardError
        attr_reader :reason

        def initialize(reason)
          @reason = reason
          super
        end
      end

      # @param root [String] application root
      # @param key [PrivateKey] private identity key used by the source snapshot
      def initialize(root:, key:)
        @root = File.expand_path(root.to_s)
        @key = key
      end

      # Read original bytes without advancing any source-consumption ledger.
      # The time budget is cooperative between bounded regular-file reads.
      #
      # @param path [String] root-relative or absolute application path
      # @param identity [String] HMAC from the session snapshot
      # @param max_bytes [Numeric] maximum bytes retained in memory
      # @param max_seconds [Numeric] maximum elapsed read time
      # @return [Hash] frozen path, binary source bytes and captured HMAC
      # @raise [Error] if containment, stability, identity or bounds cannot be proven
      def read(path, identity:, max_bytes: DEFAULT_LIMITS[:max_bytes], max_seconds: DEFAULT_LIMITS[:max_seconds])
        @limits = { max_bytes: max_bytes, max_seconds: max_seconds }
        validate_limits!
        @started = monotonic
        absolute = File.expand_path(path.to_s, @root)
        resolved = resolve(absolute)
        expected = stamp(File.stat(resolved))
        source = read_stable(absolute, resolved, expected)
        actual = OpenSSL::HMAC.hexdigest('SHA256', @key.bytes, source)
        check_time!
        raise Error, 'source_snapshot_mismatch' unless actual == identity

        { 'path' => absolute.delete_prefix("#{@root}/").freeze, 'source' => source.freeze,
          'identity' => identity.dup.freeze }
      rescue SystemCallError, IOError
        raise Error, 'source_file_unreadable'
      end

      private

      def validate_limits!
        return if @limits.values.all? { |value| value.is_a?(Numeric) && value.finite? && value.positive? }

        raise ArgumentError, 'source read limits must be finite and positive'
      end

      def resolve(path)
        raise Error, 'source_outside_root' unless path.start_with?("#{@root}/")

        @resolved_root = File.realpath(@root)
        resolved = File.realpath(path)
        raise Error, 'source_outside_root' unless resolved.start_with?("#{@resolved_root}/")

        resolved
      end

      def read_stable(path, resolved, expected)
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(resolved, flags) do |file|
          file.binmode
          before = stamp(file.stat)
          raise Error, 'nonregular_source' unless file.stat.file?
          raise Error, 'source_changed_during_read' unless before == expected && stable_path?(path, resolved)
          raise Error, 'source_read_byte_budget' if file.stat.size > @limits[:max_bytes]

          source = read_bytes(file)
          verify_after!(file, before, path, resolved)
          source
        end
      end

      def verify_after!(file, before, path, resolved)
        return if before == stamp(file.stat) && before == stamp(File.stat(resolved)) && stable_path?(path, resolved)

        raise Error, 'source_changed_during_read'
      end

      def read_bytes(file)
        source = String.new(encoding: Encoding::BINARY)
        loop do
          check_time!
          chunk = file.read(16_384)
          break unless chunk
          raise Error, 'source_read_byte_budget' if source.bytesize + chunk.bytesize > @limits[:max_bytes]

          source << chunk
        end
        check_time!
        source
      end

      def stable_path?(path, resolved)
        File.realpath(@root) == @resolved_root && File.realpath(path) == resolved
      end

      def stamp(stat)
        [stat.dev, stat.ino, stat.size, stat.mtime.to_r, stat.ctime.to_r]
      end

      def check_time!
        raise Error, 'source_read_time_budget' if monotonic - @started > @limits[:max_seconds]
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
