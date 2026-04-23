# frozen_string_literal: true

require 'pathname'
require 'woods/storage/metadata_store'
require 'woods/mcp/errors'

module Woods
  module Storage
    module Snapshotter
      # Stub implementation of the metadata store snapshotter for PR 2.
      #
      # +load_or_empty+ always returns a fresh {MetadataStore::InMemory} — the real
      # MessagePack read path is wired in PR 3.
      #
      # +dump+ is a validated no-op — the real write path (+metadata.msgpack+) is
      # wired in PR 3.
      #
      # Input validation IS load-bearing even for stubs:
      # - Raises {InapplicableBackend} if +store+ does not respond to both +#each_entry+
      #   and +#bulk_load+ (the persistence seam contract).
      # - Raises +ArgumentError+ if +dump_dir+ is not under +artifact.dumps_root+.
      #
      # @see Snapshotter::Vector companion class for vector stores
      module Metadata
        # Returns an empty in-memory metadata store.
        #
        # PR 3 will replace this stub with a real MessagePack read of +metadata.msgpack+
        # from +artifact.latest_dump_path+. Callers must not assume the store is populated.
        #
        # @param artifact [Woods::IndexArtifact] the artifact layout object
        # @param resolved_config [#dimension, nil] reserved for PR 3 dimension validation
        # @return [Woods::Storage::MetadataStore::InMemory]
        def self.load_or_empty(artifact, resolved_config: nil) # rubocop:disable Lint/UnusedMethodArgument
          MetadataStore::InMemory.new
        end

        # No-op dump — validates inputs then returns without writing anything.
        #
        # PR 3 will replace the body with real MessagePack serialization.
        #
        # @param store [#each_entry, #bulk_load] an in-memory MetadataStore adapter
        # @param artifact [Woods::IndexArtifact] the artifact layout object
        # @param dump_dir [Pathname, String] target directory; must be under +artifact.dumps_root+
        # @return [void]
        # @raise [Woods::Storage::InapplicableBackend] if +store+ lacks +#each_entry+ or +#bulk_load+
        # @raise [ArgumentError] if +dump_dir+ is not under +artifact.dumps_root+
        def self.dump(store, artifact, dump_dir)
          validate_store!(store)
          validate_dump_dir!(artifact, dump_dir)
          # no-op: real write path wired in PR 3
        end

        class << self
          private

          def validate_store!(store)
            return if store.respond_to?(:each_entry) && store.respond_to?(:bulk_load)

            raise InapplicableBackend,
                  "backend #{store.class} is already durable — Snapshotter should not have been invoked"
          end

          def validate_dump_dir!(artifact, dump_dir)
            dump_path = Pathname.new(dump_dir.to_s).expand_path
            root = artifact.dumps_root.expand_path

            return if dump_path.to_s.start_with?("#{root}/") || dump_path == root

            raise ArgumentError,
                  "dump_dir #{dump_path} is not under artifact.dumps_root #{root}"
          end
        end
      end
    end
  end
end
