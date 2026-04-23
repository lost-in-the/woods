# frozen_string_literal: true

require 'pathname'
require 'tempfile'
require 'woods/storage/vector_store'
require 'woods/mcp/errors'
require 'woods/version'

module Woods
  module Storage
    module Snapshotter
      # Reads and writes the +vectors.bin+ / +vectors.idx+ on-disk format.
      #
      # Binary layout of +vectors.bin+ (all integers little-endian):
      #
      #   offset  length   field
      #     0     4 bytes  magic "WVF1"
      #     4     4 bytes  schema_version (u32 LE)
      #     8     4 bytes  dimension (u32 LE)
      #    12     8 bytes  vector_count (u64 LE)
      #    20     4 bytes  gem_version_length (u32 LE)
      #    24     N bytes  gem_version (UTF-8)
      #    24+N   4 bytes  model_name_length (u32 LE)
      #    28+N   M bytes  model_name (UTF-8)
      #    ...    —        packed float32 data (vector_count × dimension × 4 bytes)
      #
      # +vectors.idx+ (one record per vector):
      #   4 bytes  id_length (u32 LE) + N bytes id (UTF-8) + 8 bytes offset (u64 LE)
      #
      # Atomic writes use +Tempfile+ + +File.rename+ for crash safety.
      #
      # @see Snapshotter::Metadata companion for metadata stores
      module Vector # rubocop:disable Metrics/ModuleLength
        MAGIC = 'WVF1'
        SCHEMA_VERSION_SUPPORTED = 1

        # Returns a populated in-memory vector store loaded from the latest dump,
        # or an empty store when no dump exists yet.
        #
        # @param artifact [Woods::IndexArtifact] artifact layout object
        # @param resolved_config [#dimension, nil] used for dimension validation
        # @return [Woods::Storage::VectorStore::InMemory]
        # @raise [Woods::MCP::UnsupportedArtifact] if magic or schema_version is invalid
        # @raise [Woods::MCP::DimensionMismatch] if stored dimension ≠ +resolved_config.dimension+
        def self.load_or_empty(artifact, resolved_config: nil)
          dump_dir = artifact.latest_dump_path
          return VectorStore::InMemory.new if dump_dir.nil?

          bin_path = dump_dir.join('vectors.bin')
          idx_path = dump_dir.join('vectors.idx')
          return VectorStore::InMemory.new unless bin_path.exist? && idx_path.exist?

          load_from(bin_path, idx_path, resolved_config)
        end

        # Writes +vectors.bin+ and +vectors.idx+ into +dump_dir+ atomically.
        #
        # @param store [#each_entry, #bulk_load] in-memory vector store adapter
        # @param artifact [Woods::IndexArtifact] artifact layout object
        # @param dump_dir [Pathname, String] target directory; must be under +artifact.dumps_root+
        # @param resolved_config [#model_name, nil] model name written to header
        # @return [void]
        # @raise [Woods::Storage::InapplicableBackend] if +store+ lacks +#each_entry+ / +#bulk_load+
        # @raise [ArgumentError] if +dump_dir+ is not under +artifact.dumps_root+
        def self.dump(store, artifact, dump_dir, resolved_config: nil)
          validate_store!(store)
          validate_dump_dir!(artifact, Pathname.new(dump_dir.to_s))
          model_name = resolved_config.respond_to?(:model_name) ? resolved_config.model_name.to_s : ''
          entries = store.each_entry.to_a
          write_bin_and_idx(Pathname.new(dump_dir.to_s), entries, Woods::VERSION, model_name)
          nil
        end

        class << self # rubocop:disable Metrics/ClassLength
          private

          def load_from(bin_path, idx_path, resolved_config)
            bin_data = File.binread(bin_path.to_s)
            header, data_offset = parse_header(bin_data, bin_path)
            validate_magic!(header[:magic], bin_path)
            validate_schema_version!(header[:schema_version], bin_path)
            dim = resolved_config.respond_to?(:dimension) ? resolved_config.dimension : nil
            validate_dimension!(header[:dimension], dim, bin_path) if dim
            floats = bin_data.byteslice(data_offset, header[:vector_count] * header[:dimension] * 4)
                             .unpack("e#{header[:vector_count] * header[:dimension]}")
            hydrate_store(parse_idx(idx_path), floats, header[:dimension])
          end

          def parse_header(bin_data, bin_path)
            if bin_data.bytesize < 20
              raise Woods::MCP::UnsupportedArtifact.new(
                "#{bin_path}: file too short to contain a valid WVF1 header",
                details: { path: bin_path.to_s, found: bin_data.byteslice(0, 4) }
              )
            end
            magic = bin_data.byteslice(0, 4)
            schema_version, dimension = bin_data.byteslice(4, 8).unpack('L<L<')
            vector_count = bin_data.byteslice(12, 8).unpack1('Q<')
            gv_len = bin_data.byteslice(20, 4).unpack1('L<')
            off = 24 + gv_len
            mn_len = bin_data.byteslice(off, 4).unpack1('L<')
            off += 4 + mn_len
            [{ magic: magic, schema_version: schema_version,
               dimension: dimension, vector_count: vector_count }, off]
          end

          def parse_idx(idx_path)
            idx_data = File.binread(idx_path.to_s)
            pairs = []
            pos = 0
            while pos < idx_data.bytesize
              id_len = idx_data.byteslice(pos, 4).unpack1('L<')
              pos += 4
              id = idx_data.byteslice(pos, id_len)
              pos += id_len + 8 # skip the u64 offset (not needed for load)
              pairs << id
            end
            pairs
          end

          def hydrate_store(ids, floats, dim)
            store = VectorStore::InMemory.new
            entries = ids.each_with_index.map do |id, idx|
              { id: id, vector: floats[(idx * dim), dim], metadata: {} }
            end
            store.bulk_load(entries)
            store
          end

          def validate_magic!(found, path)
            return if found == MAGIC

            raise Woods::MCP::UnsupportedArtifact.new(
              "#{path}: invalid magic bytes (expected #{MAGIC.inspect}, found #{found.inspect})",
              details: { path: path.to_s, expected: MAGIC, found: found }
            )
          end

          def validate_schema_version!(version, path)
            return if version <= SCHEMA_VERSION_SUPPORTED

            raise Woods::MCP::UnsupportedArtifact.new(
              "#{path}: schema_version #{version} > supported max #{SCHEMA_VERSION_SUPPORTED}; " \
              'upgrade the woods gem to read this artifact',
              details: { path: path.to_s, artifact_version: version, max_supported: SCHEMA_VERSION_SUPPORTED }
            )
          end

          def validate_dimension!(stored, expected, path)
            return if stored == expected

            raise Woods::MCP::DimensionMismatch.new(
              "#{path}: stored dimension #{stored} ≠ provider dimension #{expected}",
              details: { path: path.to_s, stored_dimension: stored, provider_dimension: expected }
            )
          end

          def write_bin_and_idx(dump_dir, entries, gem_version, model_name)
            header = build_header(entries, gem_version, model_name)
            float_blob = entries.flat_map { |(_id, vector, _meta)| vector }.pack('e*')
            idx_data = build_idx(entries, header.bytesize)
            atomic_write(dump_dir.join('vectors.bin'), header + float_blob, binary: true)
            atomic_write(dump_dir.join('vectors.idx'), idx_data, binary: true)
          end

          def build_header(entries, gem_version, model_name)
            dim = entries.empty? ? 0 : entries.first[1].size
            gv = gem_version.encode('UTF-8').b
            mn = model_name.encode('UTF-8').b
            buf = String.new(encoding: 'BINARY')
            buf << MAGIC << [SCHEMA_VERSION_SUPPORTED, dim].pack('L<L<')
            buf << [entries.size].pack('Q<')
            buf << [gv.bytesize].pack('L<') << gv
            buf << [mn.bytesize].pack('L<') << mn
            buf
          end

          def build_idx(entries, header_size)
            buf = String.new(encoding: 'BINARY')
            float_offset = header_size
            entries.each do |id, vector, _meta|
              id_bytes = id.encode('UTF-8').b
              buf << [id_bytes.bytesize].pack('L<') << id_bytes
              buf << [float_offset].pack('Q<')
              float_offset += vector.size * 4
            end
            buf
          end

          def atomic_write(path, content, binary: false)
            FileUtils.mkdir_p(path.dirname) unless path.dirname.exist?
            tmp = Tempfile.new('.woods-vec-', path.dirname.to_s)
            tmp.binmode if binary
            tmp.write(content)
            tmp.flush
            tmp.fsync
            tmp.close
            File.rename(tmp.path, path.to_s)
          rescue StandardError
            tmp&.close
            tmp&.unlink
            raise
          end

          def validate_store!(store)
            return if store.respond_to?(:each_entry) && store.respond_to?(:bulk_load)

            raise InapplicableBackend,
                  "backend #{store.class} is already durable — Snapshotter should not have been invoked"
          end

          def validate_dump_dir!(artifact, dump_path)
            expanded = dump_path.expand_path
            root = artifact.dumps_root.expand_path
            return if expanded.to_s.start_with?("#{root}/") || expanded == root

            raise ArgumentError,
                  "dump_dir #{expanded} is not under artifact.dumps_root #{root}"
          end
        end
      end
    end
  end
end
