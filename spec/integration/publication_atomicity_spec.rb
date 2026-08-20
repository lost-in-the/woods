# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'json'
require 'woods/atomic_file'
require 'woods/generation'
require 'woods/mcp/index_reader'

# Publication atomicity — the boundary between "which generation is published"
# and "which files a reader actually loads".
#
# `generation.json` is bumped atomically and last, so a reader that sees
# generation N knows N landed. But the *payload* it points at is a directory of
# independently-written files. A reader that resolves each artifact against
# whatever is on disk when it reaches it can load a unit from N+1 next to a
# manifest from N — one response describing two indexes. Pinning suppresses
# cache *invalidation*, but a never-read artifact still loads from disk as it
# stands (see index_reader_freshness_spec's documented limit).
#
# The fix is an immutable per-generation payload directory named by an atomic
# pointer: the reader resolves every artifact of a read through the ONE payload
# the generation named at the top of that read. This spec drives the
# reader-side half of that contract.
RSpec.describe 'Publication atomicity', type: :integration do
  let(:dir) { Dir.mktmpdir('woods_pub_atomicity') }

  after { FileUtils.rm_rf(dir) }

  # Collision-safe unit filename, matching IndexReader#build_identifier_map.
  def unit_filename(identifier)
    base = identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
    digest = Digest::SHA256.hexdigest(identifier)[0, 8]
    "#{base}_#{digest}.json"
  end

  # Write a whole payload (manifest + one models unit + its _index.json) into
  # +root+. Used both for a flat index (root == index dir) and for an immutable
  # staged payload directory (root == index_dir/payloads/gen-N).
  def write_payload(root, total_units:, post_body:)
    FileUtils.mkdir_p(File.join(root, 'models'))
    File.write(File.join(root, 'manifest.json'),
               JSON.generate('total_units' => total_units, 'counts' => { 'models' => total_units }))
    File.write(File.join(root, 'models', unit_filename('Post')),
               JSON.generate('identifier' => 'Post', 'type' => 'model', 'source_code' => post_body,
                             'metadata' => {}, 'dependencies' => [], 'dependents' => []))
    File.write(File.join(root, 'models', '_index.json'),
               JSON.generate([{ 'identifier' => 'Post', 'chunk_count' => 1 }]))
  end

  # Publish an immutable payload dir and flip the atomic generation pointer at
  # it. Returns the generation number published.
  def publish(name, number:, total_units:, post_body:, reason: 'full')
    payload_root = File.join(dir, 'payloads', name)
    write_payload(payload_root, total_units: total_units, post_body: post_body)
    Woods::AtomicFile.write(
      File.join(dir, Woods::Generation::FILENAME),
      JSON.generate('number' => number, 'token' => "tok#{number}",
                    'updated_at' => nil, 'reason' => reason, 'payload' => "payloads/#{name}")
    )
    number
  end

  describe 'a reader honoring the atomic payload pointer' do
    it 'resolves the manifest through the payload the generation names, not the root' do
      # A stale/sentinel copy at the root must not be what the reader serves
      # when the generation names a payload directory.
      write_payload(dir, total_units: 999, post_body: 'ROOT SENTINEL')
      publish('gen-1', number: 1, total_units: 1, post_body: 'class Post; end')

      reader = Woods::MCP::IndexReader.new(dir)

      expect(reader.manifest['total_units']).to eq(1)
      expect(reader.find_unit('Post')['source_code']).to eq('class Post; end')
    end

    it 'moves to the whole new payload after the pointer flips' do
      write_payload(dir, total_units: 999, post_body: 'ROOT SENTINEL')
      publish('gen-1', number: 1, total_units: 1, post_body: 'v1')
      reader = Woods::MCP::IndexReader.new(dir)
      expect(reader.manifest['total_units']).to eq(1)

      publish('gen-2', number: 2, total_units: 2, post_body: 'v2')

      expect(reader.manifest['total_units']).to eq(2)
      expect(reader.find_unit('Post')['source_code']).to eq('v2')
    end

    # The atomicity guarantee the flat layout cannot give: inside a pinned
    # read, EVERY artifact — including one never read before — resolves through
    # the single generation observed at entry, even as a new payload is
    # published mid-block. Whole old, then (after the pin) whole new. Never a
    # mix.
    it 'serves one generation for the whole pinned read, including never-read artifacts' do
      write_payload(dir, total_units: 999, post_body: 'ROOT SENTINEL')
      publish('gen-1', number: 1, total_units: 1, post_body: 'v1')
      reader = Woods::MCP::IndexReader.new(dir)
      reader.manifest # warm the manifest at gen-1, leave the Post unit never-read

      seen = reader.with_pinned_generation do
        manifest_units = reader.manifest['total_units']
        # A whole new immutable payload lands and the pointer flips mid-block.
        publish('gen-2', number: 2, total_units: 2, post_body: 'v2')
        # The Post unit was never read at gen-1; on a flat index it would load
        # gen-2's bytes here. Behind the pointer it must still be gen-1's.
        [manifest_units, reader.find_unit('Post')['source_code']]
      end

      expect(seen).to eq([1, 'v1'])
      # After the pin releases, the next read observes the whole new payload.
      expect(reader.find_unit('Post')['source_code']).to eq('v2')
      expect(reader.manifest['total_units']).to eq(2)
    end
  end

  describe 'back-compat: a flat index written the old way (no payload pointer)' do
    it 'still loads, resolving artifacts against the index root' do
      write_payload(dir, total_units: 7, post_body: 'flat body')
      # A generation file with no payload field — every index written before
      # this change, and third-party indexes.
      Woods::AtomicFile.write(
        File.join(dir, Woods::Generation::FILENAME),
        JSON.generate('number' => 1, 'token' => 'tok1', 'updated_at' => nil, 'reason' => 'full')
      )

      reader = Woods::MCP::IndexReader.new(dir)

      expect(reader.manifest['total_units']).to eq(7)
      expect(reader.find_unit('Post')['source_code']).to eq('flat body')
    end

    it 'loads an index with no generation file at all against the root' do
      write_payload(dir, total_units: 3, post_body: 'pre-generation body')

      reader = Woods::MCP::IndexReader.new(dir)

      expect(reader.manifest['total_units']).to eq(3)
      expect(reader.find_unit('Post')['source_code']).to eq('pre-generation body')
    end

    # A pointer whose directory is gone (pruned by retention, or a torn write)
    # must degrade to the root, never fail the read or read outside the index.
    it 'falls back to the root when the payload pointer names a missing directory' do
      write_payload(dir, total_units: 4, post_body: 'root body')
      Woods::AtomicFile.write(
        File.join(dir, Woods::Generation::FILENAME),
        JSON.generate('number' => 1, 'token' => 'tok1', 'updated_at' => nil,
                      'reason' => 'full', 'payload' => 'payloads/never-written')
      )

      reader = Woods::MCP::IndexReader.new(dir)

      expect(reader.manifest['total_units']).to eq(4)
      expect(reader.find_unit('Post')['source_code']).to eq('root body')
    end

    it 'refuses a pointer that would escape the index root, reading the root instead' do
      write_payload(dir, total_units: 5, post_body: 'root body')
      Woods::AtomicFile.write(
        File.join(dir, Woods::Generation::FILENAME),
        JSON.generate('number' => 1, 'token' => 'tok1', 'updated_at' => nil,
                      'reason' => 'full', 'payload' => '../escape')
      )

      reader = Woods::MCP::IndexReader.new(dir)

      expect(reader.manifest['total_units']).to eq(5)
    end
  end

  # The production gap that REMAINS after this change. The extractor still
  # writes its payload as flat files under the index root (blockers below), so
  # a real index carries no payload pointer and a reader can still straddle a
  # partial publish. Closing it needs the WRITER to publish immutable
  # per-generation payload directories — cross-file work outside this task's
  # scope. Documented here so the interleaving and the remaining work are
  # pinned to a running example.
  #
  # Blockers (all outside lib/woods/generation.rb, index_artifact.rb,
  # extractor.rb, mcp/index_reader.rb):
  #   * embedding/indexer.rb globs `output_dir/**/*.json`, so any per-unit JSON
  #     snapshot under output_dir is ingested as duplicate units.
  #   * obsidian/vault_exporter.rb (note bodies), unblocked/exporter.rb,
  #     notion, resilience/index_validator.rb and watch/daemon.rb read the flat
  #     `<output_dir>/<type>/<unit>.json` layout directly and would all have to
  #     resolve through the pointer.
  it 'a flat index has no atomic boundary across a partial publish' do
    pending 'writer-side immutable payload directories are deferred cross-file work (see comment)'

    write_payload(dir, total_units: 1, post_body: 'v1')
    Woods::AtomicFile.write(
      File.join(dir, Woods::Generation::FILENAME),
      JSON.generate('number' => 1, 'token' => 'tok1', 'updated_at' => nil, 'reason' => 'full')
    )
    reader = Woods::MCP::IndexReader.new(dir)
    reader.manifest

    straddle = reader.with_pinned_generation do
      manifest_units = reader.manifest['total_units']
      # A partial publish rewrites the flat unit file in place (no pointer to
      # flip). generation.json is unchanged, so the pin does not refresh.
      File.write(File.join(dir, 'models', unit_filename('Post')),
                 JSON.generate('identifier' => 'Post', 'source_code' => 'v2'))
      [manifest_units, reader.find_unit('Post')['source_code']]
    end

    # What we WANT (and cannot yet guarantee on a flat index): whole old.
    expect(straddle).to eq([1, 'v1'])
  end
end
