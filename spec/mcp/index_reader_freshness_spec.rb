# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
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
  end

  it 'survives a corrupt generation file rather than failing the read' do
    generation.bump!(reason: 'full')
    reader = described_class.new(dir)
    reader.manifest

    File.write(File.join(dir, Woods::Generation::FILENAME), 'not json')

    expect { reader.manifest }.not_to raise_error
    expect(reader.manifest['total_units']).to eq(1)
  end
end
