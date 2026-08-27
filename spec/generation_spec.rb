# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods/generation'

RSpec.describe Woods::Generation do
  let(:dir) { Dir.mktmpdir('woods_generation') }
  let(:generation) { described_class.new(output_dir: dir, clock: -> { '2026-07-27T00:00:00Z' }) }

  after { FileUtils.rm_rf(dir) }

  describe '#current' do
    it 'reads as unpublished before anything has been written' do
      expect(generation.current).to eq(described_class::UNPUBLISHED)
      expect(generation.current.number).to eq(0)
    end

    # A reader asking "what generation is this?" of an index written before
    # generations existed wants an answer, not an exception.
    it 'reads as unpublished when the file is corrupt' do
      File.write(File.join(dir, described_class::FILENAME), 'not json')

      expect(generation.current.number).to eq(0)
    end
  end

  describe '#bump!' do
    it 'starts at one and increases monotonically' do
      expect(generation.bump!.number).to eq(1)
      expect(generation.bump!.number).to eq(2)
      expect(generation.bump!.number).to eq(3)
    end

    it 'mints a new token on every bump' do
      tokens = Array.new(3) { generation.bump!.token }

      expect(tokens.uniq.size).to eq(3)
      expect(tokens).to all(be_a(String))
    end

    it 'records why the generation moved' do
      generation.bump!(reason: 'incremental')

      expect(generation.current.reason).to eq('incremental')
      expect(generation.current.updated_at).to eq('2026-07-27T00:00:00Z')
    end

    it 'survives a reload from disk' do
      generation.bump!
      generation.bump!

      reopened = described_class.new(output_dir: dir)
      expect(reopened.current.number).to eq(2)
    end

    it 'writes valid JSON a reader can parse without this class' do
      generation.bump!(reason: 'full')
      data = JSON.parse(File.read(File.join(dir, described_class::FILENAME)))

      expect(data).to include('number' => 1, 'reason' => 'full')
    end

    it 'records an immutable payload pointer when given one' do
      generation.bump!(reason: 'full', payload: 'payloads/2026-gen-1')

      expect(generation.current.payload).to eq('payloads/2026-gen-1')
    end

    # A flat index's generation file must stay byte-for-byte what it always
    # was, so every existing on-disk index and third-party reader is unaffected.
    it 'omits the payload key entirely for a flat bump' do
      generation.bump!(reason: 'full')
      data = JSON.parse(File.read(File.join(dir, described_class::FILENAME)))

      expect(data).not_to have_key('payload')
      expect(generation.current.payload).to be_nil
    end
  end
end
