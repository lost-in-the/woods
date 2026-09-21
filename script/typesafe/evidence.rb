# frozen_string_literal: true

require 'digest'
require 'pathname'
require_relative 'response'

module WoodsDevelopment
  module TypeSafe
    # Reads preserved local bytes. Digest checks do not establish source lineage.
    module Evidence
      MAX_FILE_BYTES = 1_048_576
      MAX_TOTAL_BYTES = 4_194_304
      MANIFEST_KEYS = %w[schema_version evidence].freeze
      ENTRY_KEYS = %w[evidence_id path sha256].freeze

      class << self
        # Load an entire materialized evidence manifest or reject it.
        #
        # @param root [String, Pathname] existing directory containing the files
        # @param manifest [Hash] parsed string-keyed schema version 1 manifest
        # @return [Array<Hash>] ordered copies with exact UTF-8 content
        # @raise [InvalidEvidence] for invalid manifests or unreadable/invalid files
        def read(root:, manifest:)
          entries = validate_manifest(manifest)
          resolved_root = resolve_root(root)
          total = 0
          entries.map do |entry|
            content = read_content(resolved_root, entry, MAX_TOTAL_BYTES - total)
            total += content.bytesize
            entry.merge('content' => content)
          end
        rescue SystemCallError, IOError, ArgumentError, TypeError, EncodingError
          raise InvalidEvidence, 'Cannot read materialized evidence', cause: nil
        end

        private

        def validate_manifest(manifest)
          check_keys(manifest, MANIFEST_KEYS)
          check(manifest['schema_version'].is_a?(Integer) && manifest['schema_version'] == 1,
                'Unsupported evidence schema version')
          entries = manifest['evidence']
          check(entries.is_a?(Array) && entries.length.between?(1, 100), 'Expected 1 to 100 evidence entries')
          copies = entries.map { |entry| validate_entry(entry) }
          ids = copies.map { |entry| entry.fetch('evidence_id').b }
          check(ids.uniq.length == ids.length, 'Duplicate evidence IDs')
          copies
        end

        def validate_entry(entry)
          check_keys(entry, ENTRY_KEYS)
          copy = entry.transform_values { |value| utf8_copy(value) }
          check(copy.fetch('evidence_id').match?(/[^\p{White_Space}]/), 'Evidence ID must not be blank')
          check(copy.fetch('sha256').match?(/\A[0-9a-f]{64}\z/), 'Invalid evidence SHA-256')
          validate_path(copy.fetch('path'))
          entry.transform_values(&:dup)
        end

        def check_keys(value, keys)
          check(value.is_a?(Hash) && value.length == keys.length && keys.all? { |key| value.key?(key) },
                'Invalid evidence fields')
        end

        def utf8_copy(value)
          check(value.is_a?(String) && value.encoding.ascii_compatible?, 'Expected a UTF-8 string')
          copy = value.dup.force_encoding(Encoding::UTF_8)
          check(copy.valid_encoding?, 'Invalid UTF-8 evidence metadata')
          copy
        end

        def validate_path(path)
          check(!path.empty? && !path.start_with?('/') && !path.match?(/\A[A-Za-z]:|[\x00\\]/),
                'Invalid relative evidence path')
          check(path.split('/', -1).none? { |part| part.empty? || part == '.' || part == '..' },
                'Invalid evidence path component')
        end

        def resolve_root(root)
          check(root.is_a?(String) || root.is_a?(Pathname), 'Invalid evidence root')
          resolved = File.realpath(root).b
          check(File.directory?(resolved), 'Evidence root must be a directory')
          resolved
        end

        def resolve_file(root, path)
          resolved = File.realpath(File.join(root, path.b))
          # The separator prevents sibling-prefix escapes; File.join also handles /.
          check(resolved.start_with?(File.join(root, '')), 'Evidence target is outside the root')
          check(File.stat(resolved).file?, 'Evidence target must be a regular file')
          resolved
        end

        def read_content(root, entry, remaining)
          path = resolve_file(root, entry.fetch('path'))
          limit = [MAX_FILE_BYTES, remaining].min
          # Regular-file validation happens before open, so FIFOs are never read.
          # The finite read rejects oversize files without allocating their full size.
          bytes = File.open(path, 'rb') { |io| io.read(limit + 1) || ''.b }
          check(bytes.bytesize <= limit, 'Evidence byte limit exceeded')
          check(Digest::SHA256.hexdigest(bytes) == entry.fetch('sha256'), 'Evidence SHA-256 mismatch')
          bytes.force_encoding(Encoding::UTF_8)
          check(bytes.valid_encoding?, 'Invalid UTF-8 evidence content')
          bytes
        end

        def check(condition, message)
          raise InvalidEvidence, message unless condition
        end
      end
    end
  end
end
