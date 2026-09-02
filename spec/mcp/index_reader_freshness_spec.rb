# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'timeout'
require 'woods'
require 'woods/mcp/index_reader'
require 'woods/generation'

# The freshness half of #164 phase 3.
#
# A long-lived MCP server used to hold whatever it read at boot until someone
# called the `reload` tool. An agent working alongside a running extraction
# therefore got answers describing the tree as of the last time the server
# happened to start — and nothing about the response said so. The generation
# check makes `reload` an optimization rather than a correctness requirement.
RSpec.describe Woods::MCP::IndexReader, 'generation-based self-refresh' do
  let(:dir) { Dir.mktmpdir('woods_reader_freshness') }
  let(:generation) { Woods::Generation.new(output_dir: dir) }

  after { FileUtils.rm_rf(dir) }

  def write_manifest(total_units:)
    File.write(File.join(dir, 'manifest.json'),
               JSON.generate('total_units' => total_units, 'counts' => { 'models' => total_units }))
  end

  # Simulate an extraction: rewrite the index, then bump the generation last.
  def republish(total_units:, reason: 'incremental')
    write_manifest(total_units: total_units)
    generation.bump!(reason: reason)
  end

  before { write_manifest(total_units: 1) }

  it 'serves fresh data after a republish without anyone calling reload' do
    generation.bump!(reason: 'full')
    reader = described_class.new(dir)
    expect(reader.manifest['total_units']).to eq(1)

    republish(total_units: 2)

    expect(reader.manifest['total_units']).to eq(2)
  end

  # The signature guards a parse, so a signature that fails to move means the
  # reader never opens the file and serves the stale index forever. Every other
  # double-bump in this file alternates the reason ('full' → 'incremental'),
  # which changes the payload length and so passes on the mtime+size signature
  # by accident. This one pins the case the daemon actually produces: the same
  # reason every cycle, so identical length, in one mtime tick.
  it 'notices a same-size republish inside one mtime tick' do
    generation.bump!(reason: 'incremental')
    reader = described_class.new(dir)
    expect(reader.manifest['total_units']).to eq(1)

    republish(total_units: 2, reason: 'incremental')
    # Force the pathological case rather than hoping for it: pin the generation
    # file's mtime back to what the first bump had, leaving size identical too.
    pin_generation_mtime_to(reader.instance_variable_get(:@generation_signature).first)

    expect(reader.manifest['total_units']).to eq(2)
  end

  def pin_generation_mtime_to(mtime)
    stamp = Time.at(mtime)
    File.utime(stamp, stamp, generation.path)
  end

  it 'tracks the generation its caches came from' do
    generation.bump!(reason: 'full')
    reader = described_class.new(dir)
    reader.manifest

    expect(reader.loaded_generation).to eq(1)

    republish(total_units: 2)
    reader.manifest

    expect(reader.loaded_generation).to eq(2)
  end

  it 'does not re-read while the generation is unchanged' do
    generation.bump!(reason: 'full')
    reader = described_class.new(dir)
    reader.manifest

    # Rewrite the payload *without* bumping — exactly what a partially
    # completed write looks like. The reader must not pick it up.
    write_manifest(total_units: 99)

    expect(reader.manifest['total_units']).to eq(1)
  end

  it 'leaves an index with no generation file alone' do
    reader = described_class.new(dir)
    expect(reader.manifest['total_units']).to eq(1)

    # Pre-generation indexes (and third-party ones) keep the old behaviour:
    # cached until an explicit reload.
    write_manifest(total_units: 5)

    expect(reader.manifest['total_units']).to eq(1)
    expect(reader.loaded_generation).to be_nil
  end

  it 'can be turned off for callers that want to control caching themselves' do
    generation.bump!(reason: 'full')
    reader = described_class.new(dir, auto_refresh: false)
    reader.manifest

    republish(total_units: 2)

    expect(reader.manifest['total_units']).to eq(1)

    reader.reload!
    expect(reader.manifest['total_units']).to eq(2)
  end

  it 'refreshes every cached artifact, not just the manifest' do
    File.write(File.join(dir, 'SUMMARY.md'), 'first')
    generation.bump!(reason: 'full')
    reader = described_class.new(dir)
    expect(reader.summary).to eq('first')

    File.write(File.join(dir, 'SUMMARY.md'), 'second')
    generation.bump!(reason: 'incremental')

    expect(reader.summary).to eq('second')
  end

  # Per-read freshness bounds staleness but does not make a *sequence* of
  # reads consistent — a caller assembling an answer from several artifacts
  # can straddle two generations. Pinning closes that window.
  describe '#with_pinned_generation' do
    it 'leaves direct multi-read callers responsible for pinning their sequence' do
      generation.bump!(reason: 'full')
      reader = described_class.new(dir)
      first_read = Queue.new
      continue_reading = Queue.new
      seen = Thread.new do
        first = reader.manifest['total_units']
        first_read << true
        continue_reading.pop
        [first, reader.manifest['total_units']]
      end
      first_read.pop

      republish(total_units: 2)
      continue_reading << true

      expect(seen.value).to eq([1, 2])
    ensure
      continue_reading << true if seen&.alive?
      seen&.join(1)
    end

    it 'does not drop already-loaded caches partway through a sequence' do
      File.write(File.join(dir, 'SUMMARY.md'), 'first')
      generation.bump!(reason: 'full')
      reader = described_class.new(dir)
      reader.manifest
      reader.summary

      seen = reader.with_pinned_generation do
        first = reader.manifest['total_units']
        File.write(File.join(dir, 'SUMMARY.md'), 'second')
        republish(total_units: 2)
        [first, reader.summary]
      end

      expect(seen).to eq([1, 'first'])
    end

    # The documented limit: pinning suppresses invalidation, it does not
    # snapshot. An artifact first read inside the block comes from disk as it
    # is then.
    it 'still loads a never-read artifact from disk as it stands' do
      generation.bump!(reason: 'full')
      reader = described_class.new(dir)
      reader.manifest

      seen = reader.with_pinned_generation do
        File.write(File.join(dir, 'SUMMARY.md'), 'written mid-block')
        reader.summary
      end

      expect(seen).to eq('written mid-block')
    end

    it 'picks up the newer generation on the next read after the block' do
      generation.bump!(reason: 'full')
      reader = described_class.new(dir)
      reader.with_pinned_generation { reader.manifest }

      republish(total_units: 2)

      expect(reader.manifest['total_units']).to eq(2)
    end

    it 'checks freshness once on entry so the pinned view is not itself stale' do
      generation.bump!(reason: 'full')
      reader = described_class.new(dir)
      reader.manifest

      republish(total_units: 3)

      expect(reader.with_pinned_generation { reader.manifest['total_units'] }).to eq(3)
    end

    it 'releases the pin when the block raises' do
      generation.bump!(reason: 'full')
      reader = described_class.new(dir)

      expect { reader.with_pinned_generation { raise 'boom' } }.to raise_error('boom')

      republish(total_units: 2)
      expect(reader.manifest['total_units']).to eq(2)
    end

    # Pins are refcounted because `woods-mcp-http` runs tool handlers on its
    # Rack server's request threads. With a boolean, the first of two
    # overlapping pins to finish unpinned the reader for both — the survivor's
    # remaining reads could then be invalidated mid-sequence, the exact tear
    # pinning exists to prevent.
    it 'holds the pin until the last overlapping holder releases' do
      generation.bump!(reason: 'full')
      reader = described_class.new(dir)
      reader.manifest

      entered = Queue.new
      release = Queue.new
      holder = Thread.new do
        reader.with_pinned_generation do
          entered << true
          release.pop
          reader.manifest['total_units']
        end
      end
      entered.pop

      # A second pin overlaps and finishes first; the holder is still pinned.
      reader.with_pinned_generation { reader.manifest }
      republish(total_units: 2)

      expect(reader.manifest['total_units']).to eq(1)

      release << true
      expect(holder.value).to eq(1)

      # Invalidation resumes once the last pin is gone.
      expect(reader.manifest['total_units']).to eq(2)
    end

    # MCP-5: the ride-along above is correct for the reads of a pin already
    # held — but it used to be UNBOUNDED for pins that arrive later. Refresh
    # was only ever attempted at depth 0 → 1, so on a threaded transport
    # (`woods-mcp-http` stateless, the deployment several agents share) the
    # depth never touched 0 and the reader served a retired generation for as
    # long as traffic overlapped, silently. A new pin arriving after the
    # generation moved now drains the held pins first, then refreshes.
    it 'drains held pins so a later pin observes a generation published mid-traffic' do
      generation.bump!(reason: 'full')
      reader = described_class.new(dir)
      reader.manifest

      stop = false
      entered = Queue.new
      holders = Array.new(2) do
        Thread.new do
          entered << true
          until stop
            # A request-shaped pin: long enough that the two holders overlap
            # continuously, which is the whole point — the depth must never
            # reach zero on its own.
            reader.with_pinned_generation do
              reader.manifest['total_units']
              sleep 0.004
            end
            sleep 0.001
          end
        end
      end
      2.times { entered.pop }

      republish(total_units: 2)

      served = nil
      Timeout.timeout(10) do
        20.times do
          served = reader.with_pinned_generation { reader.manifest['total_units'] }
          break if served == 2

          sleep 0.01
        end
      end

      expect(served).to eq(2)
    ensure
      stop = true
      holders&.each { |thread| thread.join(5) }
    end

    # The drain must not turn into a deadlock: a pin nested inside a held pin
    # rides its owner's generation instead of waiting for a drain that can only
    # happen after that owner returns.
    it 'lets a nested pin proceed while a refresh is pending' do
      generation.bump!(reason: 'full')
      reader = described_class.new(dir)
      reader.manifest

      seen = Timeout.timeout(10) do
        reader.with_pinned_generation do
          republish(total_units: 2)
          reader.with_pinned_generation { reader.manifest['total_units'] }
        end
      end

      expect(seen).to eq(1)
      expect(reader.manifest['total_units']).to eq(2)
    end
  end

  describe '#with_exclusive_reload' do
    it 'reloads the post-publication manifest before yielding it' do
      reader = described_class.new(dir, auto_refresh: false)
      expect(reader).to respond_to(:with_exclusive_reload)
      expect(reader.manifest['total_units']).to eq(1)
      write_manifest(total_units: 2)

      seen = reader.with_exclusive_reload do |manifest|
        [manifest['total_units'], reader.manifest['total_units']]
      end

      expect(seen).to eq([2, 2])
    end

    it 'releases blocked readers when the exclusive block raises' do
      reader = described_class.new(dir, auto_refresh: false)
      expect(reader).to respond_to(:with_exclusive_reload)

      expect do
        reader.with_exclusive_reload { raise 'reload response failed' }
      end.to raise_error('reload response failed')

      expect do
        Timeout.timeout(1) { reader.with_pinned_generation { reader.manifest } }
      end.not_to raise_error
    end

    it 'allows shared nesting by the exclusive owner but rejects exclusive upgrades and recursion' do
      reader = described_class.new(dir, auto_refresh: false)
      expect(reader).to respond_to(:with_exclusive_reload)

      nested_manifest = reader.with_exclusive_reload do
        reader.with_pinned_generation { reader.manifest['total_units'] }
      end
      expect(nested_manifest).to eq(1)

      expect do
        reader.with_pinned_generation { reader.with_exclusive_reload { nil } }
      end.to raise_error(ThreadError, /pinned generation/)
      expect do
        reader.with_exclusive_reload { reader.with_exclusive_reload { nil } }
      end.to raise_error(ThreadError, /already owns/)
    end
  end

  it 'survives a corrupt generation file rather than failing the read' do
    generation.bump!(reason: 'full')
    reader = described_class.new(dir)
    reader.manifest

    File.write(File.join(dir, Woods::Generation::FILENAME), 'not json')

    expect { reader.manifest }.not_to raise_error
    expect(reader.manifest['total_units']).to eq(1)
  end

  # bump! is a read-modify-write, so two overlapping writers can publish the
  # same number. Comparing numbers, a reader already loaded at N+1 concludes it
  # is current and serves the *other* writer's N+1 forever. The token is fresh
  # per publish and distinguishes them.
  it 'notices a republish that collapsed onto the same generation number' do
    generation.bump!(reason: 'incremental')
    reader = described_class.new(dir)
    expect(reader.manifest['total_units']).to eq(1)

    # A second writer republishes at the same number with a different token.
    write_manifest(total_units: 2)
    collided = JSON.parse(File.read(generation.path)).merge('token' => 'ffffffffffffffff')
    Woods::AtomicFile.write(generation.path, JSON.generate(collided))

    expect(reader.manifest['total_units']).to eq(2)
  end

  it 'falls back to the number for pre-token generation files' do
    write_manifest(total_units: 1)
    Woods::AtomicFile.write(generation.path, JSON.generate('number' => 1, 'updated_at' => nil))
    reader = described_class.new(dir)
    expect(reader.manifest['total_units']).to eq(1)

    write_manifest(total_units: 2)
    Woods::AtomicFile.write(generation.path, JSON.generate('number' => 2, 'updated_at' => nil))

    expect(reader.manifest['total_units']).to eq(2)
  end

  # CORE-4: the retention-pin loop retried on ENOENT by reloading the
  # generation and trying again. With the pointer unchanged and the payload
  # directory present but its manifest.json gone, every iteration took the
  # same path — no sleep, no cap, no fallthrough — so the request thread spun
  # at 100% CPU forever instead of degrading to an unpinned read. Only
  # tampering produces that shape (every published payload carries a
  # manifest), but the failure mode has to be a degraded read, not a hang.
  it 'proceeds unpinned when the payload directory has lost its manifest' do
    payload_root = File.join(dir, 'payloads', 'gen-1')
    FileUtils.mkdir_p(payload_root)
    File.write(File.join(payload_root, 'manifest.json'),
               JSON.generate('total_units' => 1, 'counts' => { 'models' => 1 }))
    Woods::AtomicFile.write(
      generation.path,
      JSON.generate('number' => 1, 'token' => 'tok1', 'updated_at' => nil,
                    'reason' => 'full', 'payload' => 'payloads/gen-1')
    )
    reader = described_class.new(dir)
    expect(reader.manifest['total_units']).to eq(1)

    FileUtils.rm_f(File.join(payload_root, 'manifest.json'))
    reader.reload!

    expect { Timeout.timeout(5) { reader.with_pinned_generation { reader.payload_dir } } }
      .not_to raise_error
  end
end
