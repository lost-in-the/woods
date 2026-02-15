# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'codebase_index/operator/pipeline_guard'

RSpec.describe CodebaseIndex::Operator::PipelineGuard do
  let(:state_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(state_dir) }

  subject(:guard) { described_class.new(state_dir: state_dir, cooldown: 300) }

  describe '#allow?' do
    it 'returns true when no previous run recorded' do
      expect(guard.allow?(:extraction)).to be true
    end

    it 'returns false when cooldown has not elapsed' do
      guard.record!(:extraction)
      expect(guard.allow?(:extraction)).to be false
    end

    it 'returns true when cooldown has elapsed' do
      guard.record!(:extraction)
      # Backdate the state file
      state_path = File.join(state_dir, 'pipeline_guard.json')
      state = JSON.parse(File.read(state_path))
      state['extraction'] = (Time.now - 301).iso8601
      File.write(state_path, JSON.generate(state))

      expect(guard.allow?(:extraction)).to be true
    end

    it 'tracks operations independently' do
      guard.record!(:extraction)
      expect(guard.allow?(:embedding)).to be true
    end
  end

  describe '#record!' do
    it 'persists the timestamp to disk' do
      guard.record!(:extraction)
      state_path = File.join(state_dir, 'pipeline_guard.json')
      expect(File.exist?(state_path)).to be true

      state = JSON.parse(File.read(state_path))
      expect(state).to have_key('extraction')
    end
  end

  describe '#last_run' do
    it 'returns nil when no run recorded' do
      expect(guard.last_run(:extraction)).to be_nil
    end

    it 'returns timestamp of last recorded run' do
      guard.record!(:extraction)
      expect(guard.last_run(:extraction)).to be_a(Time)
    end
  end
end
