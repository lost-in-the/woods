# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/watch/status'

RSpec.describe Woods::Watch::Status do
  let(:output_dir) { Dir.mktmpdir('woods_status') }

  after { FileUtils.rm_rf(output_dir) }

  # The one artifact with a documented cross-boundary consumer: host-side
  # worktree hooks read watch_status.json through a bind mount, so it must
  # be world-readable (O1). Everything else Woods writes stays at 0600.
  describe 'status file visibility' do
    it 'writes watch_status.json world-readable by design' do
      described_class.new(output_dir: output_dir).write(state: :running)

      path = File.join(output_dir, described_class::FILENAME)
      expect(File.stat(path).mode & 0o777).to eq(0o644)
    end
  end

  # The injected clock exists so a spec can drive staleness without sleeping
  # for a quarter of an hour. Reading the left-hand side of the comparison from
  # `Time.now` regardless made it a no-op for the one thing it is for.
  describe 'freshness against the injected clock' do
    it 'disbelieves a record older than the window' do
      now = Time.utc(2026, 1, 1, 12, 0, 0)
      described_class.new(output_dir: output_dir, clock: -> { now.iso8601 })
                     .write(state: :running)

      later = described_class.new(
        output_dir: output_dir,
        clock: -> { (now + described_class::STALE_AFTER + 60).iso8601 }
      )
      expect(later.alive?).to be false
    end

    it 'believes a record inside the window' do
      now = Time.utc(2026, 1, 1, 12, 0, 0)
      described_class.new(output_dir: output_dir, clock: -> { now.iso8601 })
                     .write(state: :running)

      soon = described_class.new(
        output_dir: output_dir,
        clock: -> { (now + 60).iso8601 }
      )
      expect(soon.alive?).to be true
    end
  end
end
