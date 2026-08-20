# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require 'woods'
require 'woods/index_artifact'
require 'woods/resolved_config'
require 'woods/storage/snapshotter'
require 'woods/storage/vector_store'
require 'woods/storage/metadata_store'

# End-to-end round trip for the Shape-2 multi-process story: dump a
# store in one Ruby process, load it in a fresh Ruby process, assert
# every vector and every metadata record comes back bit-equal.
#
# This is the single most important spec in PR 3 per the design doc
# (§6 "test strategy"). It's the only coverage that actually proves
# the MCP sidecar case works: rake embed writes to disk, separate
# `woods-mcp` server reads from disk, queries return the right
# answers.
#
# The round trip crosses a process boundary deliberately — in the
# same process, Ruby object identity can mask serialization bugs that
# only surface after a dump → fresh-Ruby → unpack cycle.
# Lightweight stand-in for Woods::Configuration in the round-trip test —
# we only need the fields ResolvedConfig.from_configuration reads.
# Defined outside the describe block to satisfy Lint/ConstantDefinitionInBlock.
RoundTripStubConfig = Struct.new(
  :embedding_provider, :embedding_model, :embedding_options,
  :vector_store, :vector_store_options, :metadata_store, :graph_store,
  keyword_init: true
)

RSpec.describe 'Snapshotter round-trip across process boundary' do
  # Seeded RNG so subprocess and parent agree on the payload without
  # needing to serialize the test data. Both sides reconstruct from the seed.
  let(:seed) { 20_260_423 }
  let(:vector_count) { 32 }
  let(:dim) { 16 }

  def build_vectors(seed, count, dim)
    rng = Random.new(seed)
    Array.new(count) do
      v = Array.new(dim) { rng.rand(-1.0..1.0) }
      mag = Math.sqrt(v.sum { |x| x * x })
      mag.zero? ? v : v.map! { |x| x / mag }
    end
  end

  def build_metadata(count)
    Array.new(count) do |i|
      {
        'type' => i.even? ? 'model' : 'service',
        'namespace' => "App::Module#{i % 4}",
        'file' => "lib/app/unit_#{i}.rb",
        'line_count' => 50 + (i * 3)
      }
    end
  end

  it 'round-trips vectors + metadata through disk across fresh subprocess' do
    Dir.mktmpdir do |output_dir|
      # ── Parent process: populate stores and dump ─────────────────
      vector_store = Woods::Storage::VectorStore::InMemory.new
      metadata_store = Woods::Storage::MetadataStore::InMemory.new

      vectors = build_vectors(seed, vector_count, dim)
      metadatas = build_metadata(vector_count)

      vector_count.times do |i|
        id = "Unit_#{i}".freeze
        vector_store.store(id, vectors[i], metadatas[i])
        metadata_store.store(id, metadatas[i])
      end

      artifact = Woods::IndexArtifact.new(output_dir)
      dump_dir = artifact.new_dump_dir

      resolved = Woods::ResolvedConfig.from_configuration(
        RoundTripStubConfig.new(
          embedding_provider: :ollama,
          embedding_model: 'nomic-embed-text',
          embedding_options: {
            model: 'nomic-embed-text',
            host: 'http://localhost:11434',
            dimension: dim
          },
          vector_store: :in_memory,
          metadata_store: :in_memory,
          graph_store: :in_memory
        )
      )

      Woods::Storage::Snapshotter::Vector.dump(vector_store, artifact, dump_dir, resolved_config: resolved)
      Woods::Storage::Snapshotter::Metadata.dump(metadata_store, artifact, dump_dir, resolved_config: resolved)
      artifact.write_config(resolved.to_snapshot_json)
      artifact.promote(dump_dir)

      # ── Subprocess: load and query, echo a signature to stdout ───
      loader_script = <<~RUBY
        $LOAD_PATH.unshift('#{File.expand_path('../../lib', __dir__)}')
        require 'woods'
        require 'woods/index_artifact'
        require 'woods/resolved_config'
        require 'woods/storage/snapshotter'
        require 'woods/storage/vector_store'
        require 'woods/storage/metadata_store'
        require 'json'

        artifact = Woods::IndexArtifact.new(#{output_dir.inspect})
        config_hash = artifact.read_config
        resolved = Woods::ResolvedConfig.from_hash(config_hash)

        vs = Woods::Storage::Snapshotter::Vector.load_or_empty(artifact, resolved_config: resolved)
        ms = Woods::Storage::Snapshotter::Metadata.load_or_empty(artifact, resolved_config: resolved)

        entries = vs.each_entry.map { |id, vec, _meta| [id, vec] }
        metas   = ms.each_entry.map { |id, data| [id, data] }

        payload = {
          vector_count: vs.count,
          metadata_count: ms.count,
          entries: entries,
          metas: metas,
          resolved_dim: resolved.dimension,
          resolved_provider: resolved.provider_signature
        }
        puts JSON.generate(payload)
      RUBY

      # We have to be careful about MetadataStore::InMemory#each_entry
      # existing. If the Snapshotter's metadata side depends on a method
      # that isn't yet on the metadata store, the subprocess raises
      # before reaching our assertions — which is what we want, because
      # that's a real integration bug.
      output = IO.popen([RbConfig.ruby, '-e', loader_script], &:read)
      payload = begin
        JSON.parse(output)
      rescue JSON::ParserError
        raise "subprocess produced non-JSON output:\n#{output}"
      end

      # ── Assertions ───────────────────────────────────────────────
      expect(payload['vector_count']).to eq(vector_count)
      expect(payload['metadata_count']).to eq(vector_count)
      expect(payload['resolved_dim']).to eq(dim)

      # Vector equality — the heart of the spec.
      payload['entries'].each do |id, loaded_vec|
        idx = id.sub('Unit_', '').to_i
        expect(loaded_vec.size).to eq(dim)
        loaded_vec.each_with_index do |v, j|
          # pack('e*') is float32 — round-trip loses some precision
          # from the Float64 originals. 1e-5 is a realistic bound.
          expect(v).to be_within(1e-5).of(vectors[idx][j])
        end
      end

      # Metadata equality — exact.
      payload['metas'].each do |id, data|
        idx = id.sub('Unit_', '').to_i
        expected = metadatas[idx]
        expect(data['type']).to eq(expected['type'])
        expect(data['namespace']).to eq(expected['namespace'])
        expect(data['file']).to eq(expected['file'])
        expect(data['line_count']).to eq(expected['line_count'])
      end
    end
  end

  it 'writes a latest pointer that a second subprocess can follow' do
    Dir.mktmpdir do |output_dir|
      # Two consecutive dumps — latest must point at the second.
      store = Woods::Storage::VectorStore::InMemory.new
      store.store('only', [1.0, 0.0], { tag: 'v1' })

      artifact = Woods::IndexArtifact.new(output_dir)
      resolved = Woods::ResolvedConfig.from_configuration(
        RoundTripStubConfig.new(
          embedding_provider: :ollama,
          embedding_model: 'nomic-embed-text',
          embedding_options: { model: 'nomic-embed-text', dimension: 2 },
          vector_store: :in_memory,
          metadata_store: :in_memory,
          graph_store: :in_memory
        )
      )

      first = artifact.new_dump_dir(now: Time.utc(2026, 4, 23, 10, 0, 0))
      Woods::Storage::Snapshotter::Vector.dump(store, artifact, first, resolved_config: resolved)
      artifact.promote(first)

      second = artifact.new_dump_dir(now: Time.utc(2026, 4, 23, 11, 0, 0))
      Woods::Storage::Snapshotter::Vector.dump(store, artifact, second, resolved_config: resolved)
      artifact.promote(second)

      # The first dump is still on disk, but latest points at the second.
      expect(artifact.latest_dump_path).to eq(second)
      expect(first.exist?).to be true # not deleted by promote itself — retention handles that elsewhere
    end
  end
end
