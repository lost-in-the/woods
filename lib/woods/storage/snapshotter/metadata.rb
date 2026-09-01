# frozen_string_literal: true

require 'pathname'
require 'tempfile'
require 'time'
require 'msgpack'
require 'woods/version'
require 'woods/atomic_file'
require 'woods/storage/metadata_store'
require 'woods/mcp/errors'

module Woods
  module Storage
    module Snapshotter
      # Reads and writes the metadata store snapshot (+metadata.msgpack+).
      #
      # MessagePack is chosen over +pack("e*")+ because metadata is heterogeneous
      # hash-shaped data — type tags matter here. The vector format uses packed
      # float32 for dense numeric data; metadata uses MessagePack for everything else.
      #
      # == On-disk format
      #
      # A stream of MessagePack-packed objects in a single file:
      #
      # 1. Header hash (one MessagePack object):
      #      { "magic" => "WMD1", "schema_version" => 1, "record_count" => N,
      #        "gem_version" => "1.2.0", "created_at" => "2026-04-23T03:42:17Z" }
      #
      # 2. One hash per record, streamed directly after the header:
      #      { "id" => "PostsController", "metadata" => { ... } }
      #
      # Stream-written via +MessagePack::Packer+ to avoid loading all records into
      # memory at once. Stream-read via +MessagePack::Unpacker+ on load. Written
      # atomically via +Tempfile+ + +File.rename+.
      #
      # @see Snapshotter::Vector companion class for vector stores
      module Metadata
        # Magic string identifying a valid Woods Metadata Dump file.
        MAGIC = 'WMD1'

        # Current schema version written by this implementation.
        SCHEMA_VERSION = 1

        # Maximum schema version this code can read. A dump with a higher version
        # raises {Woods::MCP::UnsupportedArtifact} rather than silently misreading data.
        MAX_SUPPORTED_SCHEMA_VERSION = 1

        # Filename written inside the dump directory.
        FILENAME = 'metadata.msgpack'

        # Load a metadata store from the latest dump in +artifact+, or return an
        # empty store if no dump exists yet.
        #
        # Never raises for a missing dump — callers that need an empty store on
        # first run get one without special-casing.
        #
        # @param artifact [Woods::IndexArtifact] the artifact layout object
        # @param resolved_config [Object, nil] reserved for future validation
        # @return [Woods::Storage::MetadataStore::InMemory]
        # @raise [Woods::MCP::UnsupportedArtifact] if magic is wrong or schema_version
        #   exceeds {MAX_SUPPORTED_SCHEMA_VERSION}
        def self.load_or_empty(artifact, resolved_config: nil)
          load_dump_dir(artifact.latest_dump_path, resolved_config: resolved_config)
        end

        # Load from an EXPLICIT dump directory — the reload transaction's
        # capture seam (M7). Candidates must hydrate from the dump identity
        # captured before candidate construction, never from whatever
        # +dumps/latest+ points at mid-build. By default this preserves
        # {load_or_empty}'s boot semantics. Reload transactions pass
        # +required: true+ so a missing promoted component fails closed rather
        # than replacing a healthy store with an empty one.
        #
        # @param dump_dir [Pathname, String, nil] an explicit dump directory
        # @param resolved_config [Object, nil] reserved for future validation
        # @param required [Boolean] raise when the directory or dump file is absent
        # @return [Woods::Storage::MetadataStore::InMemory]
        # @raise [Woods::MCP::MissingArtifact] when +required+ and the dump is absent
        # @raise [Woods::MCP::UnsupportedArtifact] if magic is wrong or schema_version
        #   exceeds {MAX_SUPPORTED_SCHEMA_VERSION}
        def self.load_dump_dir(dump_dir, resolved_config: nil, required: false) # rubocop:disable Lint/UnusedMethodArgument
          dump_path = dump_dir.nil? ? nil : Pathname.new(dump_dir.to_s).join(FILENAME)
          return missing_dump_store(required, dump_path) unless dump_path&.exist?

          store = MetadataStore::InMemory.new
          File.open(dump_path.to_s, 'rb') do |io|
            unpacker = MessagePack::Unpacker.new(io)
            header = unpacker.read
            validate_header!(header, dump_path)
            header['record_count'].times do
              record = unpacker.read
              store.store(record['id'], record['metadata'])
            end
          end
          store
        end

        def self.missing_dump_store(required, dump_path)
          return MetadataStore::InMemory.new unless required

          missing = dump_path&.to_s || FILENAME
          raise Woods::MCP::MissingArtifact.new(
            "Required metadata dump component is missing: #{missing}",
            details: { path: missing }
          )
        end
        private_class_method :missing_dump_store

        # Write the metadata store to +dump_dir/metadata.msgpack+ atomically.
        #
        # Streams header then one packed hash per record — no full in-memory copy
        # of the record set. Uses +Tempfile+ + +File.rename+ for atomicity.
        #
        # @param store [#each_entry, #bulk_load] an in-memory MetadataStore adapter
        # @param artifact [Woods::IndexArtifact] the artifact layout object
        # @param dump_dir [Pathname, String] target directory; must be under +artifact.dumps_root+
        # @param resolved_config [Object, nil] reserved for future use
        # @return [void]
        # @raise [Woods::Storage::InapplicableBackend] if +store+ lacks +#each_entry+ or +#bulk_load+
        # @raise [ArgumentError] if +dump_dir+ is not under +artifact.dumps_root+
        def self.dump(store, artifact, dump_dir, resolved_config: nil) # rubocop:disable Lint/UnusedMethodArgument
          validate_store!(store)
          artifact.validate_dump_dir!(dump_dir, allow_root: true)
          target = Pathname.new(dump_dir.to_s).join(FILENAME)
          target.dirname.mkpath
          write_atomic(target, store)
          nil
        end

        class << self
          private

          def dump_file_path(artifact)
            latest = artifact.latest_dump_path
            return nil unless latest

            latest.join(FILENAME)
          end

          def validate_header!(header, path)
            unless header.is_a?(Hash) && header['magic'] == MAGIC
              raise Woods::MCP::UnsupportedArtifact,
                    "metadata.msgpack at #{path} has invalid magic " \
                    "(got #{header.is_a?(Hash) ? header['magic'].inspect : 'non-hash'}; " \
                    "expected #{MAGIC.inspect}). The file may be corrupt or from an incompatible tool."
            end

            version = header['schema_version']
            return if version <= MAX_SUPPORTED_SCHEMA_VERSION

            raise Woods::MCP::UnsupportedArtifact,
                  "metadata.msgpack at #{path} has schema_version #{version}; " \
                  "this gem supports up to #{MAX_SUPPORTED_SCHEMA_VERSION}. " \
                  'Upgrade the woods gem or re-run woods:embed to regenerate.'
          end

          # Write +store+ contents to +target+ atomically via a sibling Tempfile + rename.
          # Streams header then one record hash per entry.
          #
          # @param target [Pathname] final destination
          # @param store [#count, #each_entry] populated metadata store
          def write_atomic(target, store) # rubocop:disable Metrics/AbcSize
            tmp = Tempfile.new([FILENAME, '.tmp'], target.dirname.to_s)
            begin
              tmp.binmode
              packer = MessagePack::Packer.new(tmp)
              packer.write('magic' => MAGIC, 'schema_version' => SCHEMA_VERSION,
                           'record_count' => store.count, 'gem_version' => Woods::VERSION,
                           'created_at' => Time.now.utc.iso8601)
              store.each_entry { |id, metadata| packer.write('id' => id, 'metadata' => metadata) }
              packer.flush
              tmp.flush
              tmp.fsync
              tmp.close
              File.rename(tmp.path, target.to_s)
              # Match AtomicFile: the directory entry itself must survive a
              # crash after the rename, or the dump is not durable (M11).
              Woods::AtomicFile.fsync_directory(target.dirname.to_s)
            rescue StandardError
              tmp.close
              tmp.unlink
              raise
            end
          end

          def validate_store!(store)
            return if store.respond_to?(:each_entry) && store.respond_to?(:bulk_load)

            raise InapplicableBackend,
                  "backend #{store.class} is already durable — Snapshotter should not have been invoked"
          end
        end
      end
    end
  end
end
