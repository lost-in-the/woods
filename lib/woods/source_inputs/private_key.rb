# frozen_string_literal: true

require 'securerandom'
require 'digest'
require 'fileutils'

module Woods
  module SourceInputs
    # Never copied into a published generation. Public identities are keyed even
    # for ordinary source, so an unrecognized secret-bearing file stays protected.
    class PrivateKey
      FILE_NAME = '.source-inputs.key'
      class Unavailable < StandardError
        def initialize(reason, path: nil, detail: nil)
          super(reason)
          @path = path
          @detail = detail
        end

        # Keep the machine-readable reason unchanged for freshness readers.
        # @return [String] safe launcher diagnostic without key bytes
        def diagnostic
          "#{message}: #{@path.inspect}: #{@detail}. " \
            'Verify the owner UID and mount permissions in the application environment; ' \
            'use an owner-only regular 32-byte key. Woods did not repair or rotate it. ' \
            'See docs/SOURCE_FRESHNESS.md#identity-key-recovery.'
        end
      end

      attr_reader :bytes, :identifier

      def initialize(output_dir:, create: false)
        path = File.expand_path(File.join(output_dir.to_s, FILE_NAME))
        create_key(path) if create
        @bytes = read_key(path)
        unless @bytes&.bytesize == 32
          raise Unavailable.new('invalid_identity_key', path: path, detail: 'expected exactly 32 bytes')
        end

        @identifier = Digest::SHA256.hexdigest(@bytes)
      rescue SystemCallError, IOError => e
        raise Unavailable.new(
          'identity_key_unavailable',
          path: path,
          detail: "cannot safely open a regular non-symlink key (#{e.class})"
        )
      end

      private

      # @param path [String] private identity-key path
      # @return [String] bounded key bytes after safe descriptor validation
      def read_key(path)
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |file|
          unless private_regular?(file.stat)
            raise Unavailable.new(
              'insecure_identity_key',
              path: path,
              detail: 'expected a regular file owned by this UID with owner-only permissions'
            )
          end

          file.read(33)
        end
      end

      def private_regular?(stat)
        stat.file? && stat.uid == Process.uid && stat.mode.nobits?(0o077)
      end

      def create_key(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.binmode
          file.write(SecureRandom.random_bytes(32))
          file.flush
          file.fsync
        end
      rescue Errno::EEXIST
        # Existing permissions/content are validated, never repaired implicitly.
        nil
      end
    end
  end
end
