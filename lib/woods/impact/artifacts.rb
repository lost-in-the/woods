# frozen_string_literal: true

require 'json'
require 'pathname'

module Woods
  module Impact
    # Read only bounded JSON artifacts inside one already locked payload.
    class Artifacts
      MAX_BYTES = 16 * 1024 * 1024

      # @param reader [PublishedIndex] caller owns its retention lock
      def initialize(reader)
        @root = reader.payload_dir
      end

      # @param relative [String] payload-relative path, without traversal or links
      # @return [Hash, Array] decoded JSON
      # @raise [IOError, JSON::ParserError, SystemCallError] absent or unsafe artifact
      def read(relative)
        path = guarded_path(relative)
        File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          unless file.stat.file? && file.size <= MAX_BYTES
            raise IOError,
                  'Impact artifact is not a regular bounded file'
          end

          content = file.read(MAX_BYTES + 1).force_encoding(Encoding::UTF_8)
          raise IOError, 'Impact artifact has invalid UTF-8 or exceeds byte budget' unless valid_content?(content)

          JSON.parse(content)
        end
      end

      private

      def valid_content?(content)
        content.bytesize <= MAX_BYTES && content.valid_encoding?
      end

      def guarded_path(relative)
        unless relative.is_a?(String) && relative.match?(%r{\A[a-zA-Z0-9_-]+(?:/[a-zA-Z0-9_.-]+)*\.json\z})
          raise IOError, 'Unsafe impact artifact path'
        end

        path = @root
        raise IOError, 'Symlink impact payload' if path.symlink?

        relative.split('/').each do |part|
          raise IOError, 'Unsafe impact artifact component' if %w[. ..].include?(part)

          path = path.join(part)
          raise IOError, 'Symlink impact artifact component' if path.symlink?
        end
        path
      end
    end
  end
end
