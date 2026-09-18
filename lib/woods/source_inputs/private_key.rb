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
      class Unavailable < StandardError; end

      attr_reader :bytes, :identifier

      def initialize(output_dir:, create: false)
        path = File.join(output_dir.to_s, FILE_NAME)
        create_key(path) if create
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |file|
          stat = file.stat
          raise Unavailable, 'insecure_identity_key' unless private_regular?(stat)

          @bytes = file.read(33)
        end
        raise Unavailable, 'invalid_identity_key' unless @bytes&.bytesize == 32

        @identifier = Digest::SHA256.hexdigest(@bytes)
      rescue SystemCallError, IOError
        raise Unavailable, 'identity_key_unavailable'
      end

      private

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
