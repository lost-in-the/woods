# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'json'
require 'woods/atomic_file'
require 'woods/generation'
require 'woods/payload_store'
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

  # A flat index has no atomic boundary, and never will — that is the whole
  # reason the payload layout exists. Kept as a running example rather than a
  # comment: it is what the writer-driven example below is measured against,
  # and it is the behaviour a reader still gets from an index written before
  # payloads or by a run whose payload directory could not be opened.
  it 'cannot bound a partial publish on a flat index' do
    write_payload(dir, total_units: 1, post_body: 'v1')
    Woods::AtomicFile.write(
      File.join(dir, Woods::Generation::FILENAME),
      JSON.generate('number' => 1, 'token' => 'tok1', 'updated_at' => nil, 'reason' => 'full')
    )
    reader = Woods::MCP::IndexReader.new(dir)
    reader.manifest

    straddle = reader.with_pinned_generation do
      manifest_units = reader.manifest['total_units']
      # A partial publish rewrites the flat unit file in place — there is no
      # pointer to flip, so generation.json is unchanged and the pin does not
      # refresh. The manifest is cached from before; the unit is not.
      File.write(File.join(dir, 'models', unit_filename('Post')),
                 JSON.generate('identifier' => 'Post', 'source_code' => 'v2'))
      [manifest_units, reader.find_unit('Post')['source_code']]
    end

    expect(straddle).to eq([1, 'v2'])
  end

  # The writer half. A generation publishes into its own immutable directory
  # and the single atomic write of generation.json commits it, so a reader
  # inside a pinned read sees one generation whole — including artifacts it had
  # not read yet when the next publish landed.
  describe 'a payload published per generation' do
    it 'serves the whole old generation across a complete later publish' do
      publish('gen-1', number: 1, total_units: 1, post_body: 'v1')
      reader = Woods::MCP::IndexReader.new(dir)
      reader.manifest

      straddle = reader.with_pinned_generation do
        manifest_units = reader.manifest['total_units']
        publish('gen-2', number: 2, total_units: 2, post_body: 'v2')
        [manifest_units, reader.find_unit('Post')['source_code']]
      end

      expect(straddle).to eq([1, 'v1'])
    end

    # The half a flat index cannot give: `manifest` was read before the second
    # publish, `find_unit` was not. Both must answer from generation 1.
    it 'serves an artifact first read after the later publish from the pinned generation' do
      publish('gen-1', number: 1, total_units: 1, post_body: 'v1')
      reader = Woods::MCP::IndexReader.new(dir)

      never_read = reader.with_pinned_generation do
        publish('gen-2', number: 2, total_units: 2, post_body: 'v2')
        reader.find_unit('Post')['source_code']
      end

      expect(never_read).to eq('v1')
    end

    it 'moves to the new generation once the pin is released' do
      publish('gen-1', number: 1, total_units: 1, post_body: 'v1')
      reader = Woods::MCP::IndexReader.new(dir)
      reader.with_pinned_generation { reader.manifest }

      publish('gen-2', number: 2, total_units: 2, post_body: 'v2')

      expect(reader.find_unit('Post')['source_code']).to eq('v2')
      expect(reader.manifest['total_units']).to eq(2)
    end

    it 'keeps the loaded payload pinned while the generation marker is temporarily corrupt' do
      publish('gen-1', number: 1, total_units: 1, post_body: 'v1')
      reader = Woods::MCP::IndexReader.new(dir)
      reader.manifest
      File.write(File.join(dir, Woods::Generation::FILENAME), 'not json')

      result = Timeout.timeout(1) do
        reader.with_pinned_generation { reader.find_unit('Post')['source_code'] }
      end

      expect(result).to eq('v1')
    end

    it 'keeps a generation readable while another process has it pinned' do
      publish('gen-1', number: 1, total_units: 1, post_body: 'v1')
      entered_read, entered_write = IO.pipe
      release_read, release_write = IO.pipe
      result_read, result_write = IO.pipe
      child_script = <<~'RUBY'
        begin
          require 'woods/mcp/index_reader'
          dir, entered_fd, release_fd, result_fd = ARGV
          entered = IO.for_fd(entered_fd.to_i)
          release = IO.for_fd(release_fd.to_i)
          result = IO.for_fd(result_fd.to_i)
          reader = Woods::MCP::IndexReader.new(dir)
          reader.with_pinned_generation do
            entered.write('1')
            entered.close
            release.read(1)
            result.write(reader.find_unit('Post')['source_code'])
            result.close
            # Bypass Ruby ensure blocks to model a crashed reader. The kernel
            # must still release the advisory lock so retention can reclaim it.
            exit! 0
          end
        rescue StandardError => e
          result.write("ERROR: #{e.class}: #{e.message}")
          result.close
          exit! 1
        end
      RUBY
      lib_dir = File.expand_path('../../lib', __dir__)
      child = Process.spawn(
        RbConfig.ruby, "-I#{lib_dir}", '-e', child_script,
        dir, entered_write.fileno.to_s, release_read.fileno.to_s, result_write.fileno.to_s,
        entered_write => entered_write, release_read => release_read, result_write => result_write
      )

      entered_write.close
      release_read.close
      result_write.close
      expect(entered_read.read(1)).to eq('1')

      store = Woods::PayloadStore.new(dir)
      (2..4).each do |number|
        publish("gen-#{number}", number: number, total_units: number, post_body: "v#{number}")
        store.prune(keep: 3, protect: number)
      end

      expect(store.path_for(1)).to be_directory
      release_write.write('1')
      release_write.close
      expect(result_read.read).to eq('v1')
      _pid, status = Process.wait2(child)
      child = nil
      expect(status).to be_success

      store.prune(keep: 3, protect: 4)
      expect(store.path_for(1)).not_to exist
    ensure
      [entered_read, entered_write, release_read, release_write, result_read, result_write].compact.each do |io|
        io.close unless io.closed?
      rescue IOError
        nil
      end
      if child
        begin
          Process.kill('KILL', child)
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.wait(child)
        rescue Errno::ECHILD
          nil
        end
      end
    end

    # Writing generation N+1's payload cannot disturb generation N, because
    # every writer renames a fresh tempfile over the path rather than editing
    # the inode a hardlinked clone shares.
    it 'leaves the previous payload intact when a clone is rewritten' do
      publish('gen-1', number: 1, total_units: 1, post_body: 'v1')
      store = Woods::PayloadStore.new(dir)
      target = store.create(2)
      store.clone(File.join(dir, 'payloads', 'gen-1'), target)

      Woods::AtomicFile.write(target.join('models', unit_filename('Post')),
                              JSON.generate('identifier' => 'Post', 'source_code' => 'v2'))

      previous = File.read(File.join(dir, 'payloads', 'gen-1', 'models', unit_filename('Post')))
      expect(JSON.parse(previous)['source_code']).to eq('v1')
    end
  end
end
