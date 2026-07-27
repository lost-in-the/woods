# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/watch/status'

RSpec.describe Woods::Watch::Status do
  let(:output_dir) { Dir.mktmpdir('woods_status') }

  after { FileUtils.rm_rf(output_dir) }

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
