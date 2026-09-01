# frozen_string_literal: true

require 'pathname'
require 'tempfile'
require 'woods/atomic_file'
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
          load_dump_dir(artifact.latest_dump_path, resolved_config: resolved_config)
        end

        # Load from an EXPLICIT dump directory — the reload transaction's
        # capture seam (M7). Candidates must hydrate from the dump identity
        # captured before candidate construction, never from whatever
        # +dumps/latest+ points at mid-build; +load_or_empty+ re-reads the
        # +latest+ pointer on every call and would mix halves from two dumps.
        # By default this preserves {load_or_empty}'s boot semantics: a nil
        # directory or a directory without the dump files yields an empty
        # store. Reload transactions pass +required: true+ so a partially
        # promoted dump fails closed instead of replacing a healthy store with
        # an empty one.
        #
        # @param dump_dir [Pathname, String, nil] an explicit dump directory
        # @param resolved_config [#dimension, nil] used for dimension validation
        # @param required [Boolean] raise when the directory or either dump file is absent
        # @return [Woods::Storage::VectorStore::InMemory]
        # @raise [Woods::MCP::MissingArtifact] when +required+ and a dump component is absent
        # @raise [Woods::MCP::UnsupportedArtifact] if magic or schema_version is invalid
        # @raise [Woods::MCP::DimensionMismatch] if stored dimension ≠ +resolved_config.dimension+
        def self.load_dump_dir(dump_dir, resolved_config: nil, required: false)
          return missing_dump_store(required, []) if dump_dir.nil?

          dump_dir = Pathname.new(dump_dir.to_s)
          bin_path = dump_dir.join('vectors.bin')
          idx_path = dump_dir.join('vectors.idx')
          missing = [bin_path, idx_path].reject(&:exist?)
          return missing_dump_store(required, missing) if missing.any?

          load_from(bin_path, idx_path, resolved_config)
        end

        def self.missing_dump_store(required, paths)
          return VectorStore::InMemory.new unless required

          message = if paths.empty?
                      'No promoted vector dump is available'
                    else
                      "Required vector dump component is missing: #{paths.join(', ')}"
                    end
          raise Woods::MCP::MissingArtifact.new(message, details: { paths: paths.map(&:to_s) })
        end
        private_class_method :missing_dump_store

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
            validate_dimension_if_present!(header, resolved_config, bin_path)
            floats = read_float_blob(bin_data, header, data_offset, bin_path)
            ids = parse_idx(idx_path)
            validate_idx_count!(ids.size, header[:vector_count], idx_path, bin_path)
            hydrate_store(ids, floats, header[:dimension])
          end

          # A valid header over a truncated float payload used to unpack
          # straight through: byteslice pads the missing tail with nil, so
          # nil-floated vectors hydrated into the live store, crashed search
          # with TypeError, and re-published as zeros on the next dump (M10).
          # Unpack never invents data — the blob must be complete, and a
          # truncated dump is an interrupted dump.
          def read_float_blob(bin_data, header, data_offset, path)
            float_count = header[:vector_count] * header[:dimension]
            needed = float_count * 4
            raise_truncated(path, bin_data.bytesize, data_offset + needed) if bin_data.bytesize - data_offset < needed

            bin_data.byteslice(data_offset, needed).unpack("e#{float_count}")
          end

          def parse_header(bin_data, bin_path) # rubocop:disable Metrics/AbcSize
            # Minimum header is 28 bytes (magic + schema_version + dimension
            # + vector_count + gem_version_length + model_name_length) plus
            # the variable-length gem_version and model_name strings. A
            # truncated header past the u32 guard below would produce a
            # confusing NoMethodError on nil.unpack; raise a typed error
            # with the file path instead.
            raise_truncated(bin_path, bin_data.bytesize, 28) if bin_data.bytesize < 28

            magic = bin_data.byteslice(0, 4)
            schema_version, dimension = bin_data.byteslice(4, 8).unpack('L<L<')
            vector_count = bin_data.byteslice(12, 8).unpack1('Q<')
            gv_len = bin_data.byteslice(20, 4).unpack1('L<')
            raise_truncated(bin_path, bin_data.bytesize, 24 + gv_len + 4) if bin_data.bytesize < 24 + gv_len + 4

            off = 24 + gv_len
            mn_len = bin_data.byteslice(off, 4).unpack1('L<')
            raise_truncated(bin_path, bin_data.bytesize, off + 4 + mn_len) if bin_data.bytesize < off + 4 + mn_len

            off += 4 + mn_len
            [{ magic: magic, schema_version: schema_version,
               dimension: dimension, vector_count: vector_count }, off]
          end

          def raise_truncated(path, actual, expected)
            raise Woods::MCP::UnsupportedArtifact.new(
              "#{path}: file truncated (got #{actual} bytes, need at least #{expected}) — " \
              'dump may have been interrupted mid-write; re-run woods:embed',
              details: { path: path.to_s, actual_bytes: actual, needed_bytes: expected }
            )
          end

          def parse_idx(idx_path)
            idx_data = File.binread(idx_path.to_s)
            pairs = []
            pos = 0
            while pos < idx_data.bytesize
              # Fail closed on truncation (M3), the same contract as the bin
              # side's float-blob guard: a record that would read past EOF is
              # an interrupted dump, and byteslice would otherwise pad it into
              # a garbage (short) id that silently hydrates.
              raise_truncated(idx_path, idx_data.bytesize, pos + 4) if idx_data.bytesize - pos < 4
              id_len = idx_data.byteslice(pos, 4).unpack1('L<')
              record_end = pos + 4 + id_len + 8
              raise_truncated(idx_path, idx_data.bytesize, record_end) if idx_data.bytesize < record_end
              pos += 4
              # The idx format stores ids as UTF-8 bytes (build_idx writes
              # id.encode('UTF-8').b), but byteslice on a binread buffer
              # yields ASCII-8BIT. Left untagged, a non-ASCII id is not eql?
              # to its UTF-8 twin, so every hash lookup keyed on a hydrated
              # id misses: the Indexer's checkpoint self-heal re-embedded the
              # unit on every incremental run, and InMemory#store appended a
              # duplicate live entry each time (B-080 / #192).
              id = idx_data.byteslice(pos, id_len).force_encoding(Encoding::UTF_8)
              pos += id_len + 8 # skip the u64 offset (not needed for load)
              pairs << id
            end
            pairs
          end

          # The idx record count and the bin header's vector_count describe
          # the same dump; the idx maps ids onto the blob the header counts.
          # When the halves disagree, hydration either crashed with a bare
          # NoMethodError (idx longer: nil vectors reach InMemory#store) or
          # silently served fewer vectors than the dump claims (idx shorter).
          # Promotion ordering makes live exposure post-promotion-corruption-
          # only, but the fail-closed-with-typed-error contract is the
          # file's own standard — a mismatched dump is an interrupted or
          # corrupted dump, never one to hydrate from.
          def validate_idx_count!(idx_count, bin_count, idx_path, bin_path)
            return if idx_count == bin_count

            raise Woods::MCP::UnsupportedArtifact.new(
              "#{idx_path}: vectors.idx holds #{idx_count} id records but #{bin_path} header declares " \
              "#{bin_count} vectors — dump halves disagree; re-run woods:embed",
              details: { path: idx_path.to_s, idx_count: idx_count, bin_vector_count: bin_count }
            )
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

          # An empty dump writes dimension=0 in the header (build_header has
          # no vector to measure) — that's not a real mismatch against the
          # provider's dimension, just the absence of data. Skip the check
          # rather than raising DimensionMismatch on every embed of an
          # empty payload.
          def validate_dimension_if_present!(header, resolved_config, path)
            return unless header[:vector_count].positive?

            dim = resolved_config.respond_to?(:dimension) ? resolved_config.dimension : nil
            validate_dimension!(header[:dimension], dim, path) if dim
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
            # Match AtomicFile: the directory entry itself must survive a
            # crash after the rename, or the dump is not durable (M11).
            Woods::AtomicFile.fsync_directory(path.dirname.to_s)
          rescue StandardError
            tmp&.close
            tmp&.unlink
            raise
          end

          # +respond_to?+ is the wrong question here: {VectorStore::Interface}
          # *defines* both +#each_entry+ and +#bulk_load+ (as stubs — the
          # former raises +NotImplementedError+, the latter delegates to
          # +#store_batch+), and every adapter includes that module. Durable
          # adapters (Pgvector, Qdrant) therefore answered +respond_to?+ with
          # +true+ despite implementing neither, passed this guard, and hit
          # the bare +NotImplementedError+ from +#each_entry+ instead of the
          # typed error this method promises (B-108, see
          # `Indexer#implements_own?`). Ask who *owns* the method instead.
          def validate_store!(store)
            return if implements_own?(store, :each_entry) && store.respond_to?(:bulk_load)

            raise InapplicableBackend,
                  "backend #{store.class} is already durable — Snapshotter should not have been invoked"
          end

          # Does +object+ define +method_name+ itself, rather than inheriting
          # {VectorStore::Interface}'s default stub?
          #
          # @param object [Object] the adapter under test
          # @param method_name [Symbol]
          # @return [Boolean]
          def implements_own?(object, method_name)
            return false unless object.respond_to?(method_name)
            return true unless defined?(VectorStore::Interface)

            object.method(method_name).owner != VectorStore::Interface
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
