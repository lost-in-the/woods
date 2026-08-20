# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/operator/pipeline_guard'

RSpec.describe Woods::Operator::PipelineGuard do
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

    # A corrupt state file used to be indistinguishable from "never run": both
    # parsed to `{}` and `allow?` returned true, silently defeating the
    # cooldown it exists to enforce. Missing state is genuinely fine (a fresh
    # install); corrupt or unreadable state is not, and must fail closed.
    it 'fails closed (denies) when the state file is corrupt, rather than treating it as unrun' do
      state_path = File.join(state_dir, 'pipeline_guard.json')
      File.write(state_path, '{not-json')

      expect(guard.allow?(:extraction)).to be false
    end

    it 'fails closed (denies) when the state file is unreadable' do
      state_path = File.join(state_dir, 'pipeline_guard.json')
      File.write(state_path, JSON.generate('extraction' => (Time.now - 301).iso8601))
      File.chmod(0o000, state_path)

      expect(guard.allow?(:extraction)).to be false
    ensure
      File.chmod(0o600, state_path)
    end

    it 'still allows when the state file is simply missing' do
      expect(File.exist?(File.join(state_dir, 'pipeline_guard.json'))).to be false

      expect(guard.allow?(:extraction)).to be true
    end
  end

  describe '#state_status' do
    let(:state_path) { File.join(state_dir, 'pipeline_guard.json') }

    it 'reports :missing when no state file has ever been written' do
      expect(guard.state_status).to eq(:missing)
    end

    it 'reports :ok for a valid state file' do
      guard.record!(:extraction)

      expect(guard.state_status).to eq(:ok)
    end

    it 'reports :corrupt for unparseable JSON, distinct from :missing' do
      File.write(state_path, '{not-json')

      expect(guard.state_status).to eq(:corrupt)
    end

    it 'reports :corrupt for valid JSON that is not an object' do
      File.write(state_path, '[1,2,3]')

      expect(guard.state_status).to eq(:corrupt)
    end

    it 'reports :permission_denied for a state file this process cannot read, distinct from :corrupt' do
      File.write(state_path, JSON.generate('extraction' => Time.now.iso8601))
      File.chmod(0o000, state_path)

      expect(guard.state_status).to eq(:permission_denied)
    ensure
      File.chmod(0o600, state_path)
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

  describe '#reset!' do
    let(:state_path) { File.join(state_dir, 'pipeline_guard.json') }

    it 'removes one supported operation while preserving unrelated state' do
      guard.record!(:extraction)
      guard.record!(:embedding)
      guard.record!(:custom_operation)

      expect(guard.reset!(:extraction)).to be(true)
      expect(JSON.parse(File.read(state_path)).keys)
        .to contain_exactly('embedding', 'custom_operation')
    end

    it 'removes all explicitly supported operations while preserving unrelated state' do
      guard.record!(:extraction)
      guard.record!(:embedding)
      guard.record!(:custom_operation)

      expect(guard.reset!(:all)).to be(true)
      expect(JSON.parse(File.read(state_path)).keys).to eq(['custom_operation'])
    end

    it 'returns false and leaves state unchanged when there is nothing to reset' do
      guard.record!(:custom_operation)
      original = File.binread(state_path)

      expect(guard.reset!(:all)).to be(false)
      expect(File.binread(state_path)).to eq(original)
    end

    it 'does not create a missing state file for a no-op in a read-only directory' do
      File.chmod(0o500, state_dir)

      expect(guard.reset!(:all)).to be(false)
      expect(File.exist?(state_path)).to be(false)
    ensure
      File.chmod(0o700, state_dir)
    end

    it 'does not open irrelevant state for writing in a read-only location' do
      guard.record!(:custom_operation)
      original = File.binread(state_path)
      File.chmod(0o400, state_path)
      File.chmod(0o500, state_dir)

      expect(guard.reset!(:all)).to be(false)
      expect(File.binread(state_path)).to eq(original)
    ensure
      File.chmod(0o700, state_dir)
      File.chmod(0o600, state_path) if File.exist?(state_path)
    end

    it 'leaves malformed state untouched when it parses to no requested entries' do
      File.write(state_path, '{not-json')
      File.chmod(0o400, state_path)
      File.chmod(0o500, state_dir)

      expect(guard.reset!(:all)).to be(false)
      expect(File.binread(state_path)).to eq('{not-json')
    ensure
      File.chmod(0o700, state_dir)
      File.chmod(0o600, state_path) if File.exist?(state_path)
    end

    it 'rejects unsupported operations without changing state' do
      guard.record!(:extraction)
      original = File.binread(state_path)

      expect { guard.reset!(:unknown) }.to raise_error(ArgumentError, /unknown/)
      expect(File.binread(state_path)).to eq(original)
    end

    it 'waits for a concurrent record and preserves that writer state atomically' do
      guard.record!(:extraction)
      writer_has_lock = Queue.new
      release_writer = Queue.new
      writer = Thread.new do
        File.open(state_path, File::RDWR) do |file|
          file.flock(File::LOCK_EX)
          writer_has_lock << true
          release_writer.pop
          state = JSON.parse(file.read)
          state['embedding'] = Time.now.iso8601
          file.rewind
          file.write(JSON.generate(state))
          file.truncate(file.pos)
        end
      end
      writer_has_lock.pop

      reset = Thread.new { guard.reset!(:extraction) }
      # The writer holds the file's flock (proven by writer_has_lock above);
      # a bounded join that times out is the observed-blocking proof.
      expect(reset.join(0.3)).to be_nil
      release_writer << true

      expect(reset.value).to be(true)
      expect(JSON.parse(File.read(state_path)).keys).to eq(['embedding'])
      writer.join
    end

    it 'has only linearizable outcomes when record and reset start together' do
      outcomes = 20.times.map do
        File.write(
          state_path,
          JSON.generate(
            'extraction' => Time.now.iso8601,
            'custom_operation' => Time.now.iso8601
          )
        )
        ready = Queue.new
        start = Queue.new
        resetter = Thread.new do
          ready << true
          start.pop
          guard.reset!(:all)
        end
        recorder = Thread.new do
          ready << true
          start.pop
          guard.record!(:embedding)
        end
        2.times { ready.pop }
        2.times { start << true }

        expect(resetter.value).to be(true)
        recorder.join
        JSON.parse(File.read(state_path)).keys.sort
      end

      expect(outcomes).to all(satisfy do |keys|
        [%w[custom_operation], %w[custom_operation embedding].sort].include?(keys)
      end)
    end
  end

  describe 'concurrent record!' do
    it 'preserves all operations under concurrent access' do
      threads = 10.times.map do |i|
        Thread.new do
          guard.record!(:"op_#{i}")
        end
      end
      threads.each(&:join)

      state_path = File.join(state_dir, 'pipeline_guard.json')
      state = JSON.parse(File.read(state_path))
      # All 10 operations should be present
      expect(state.keys.size).to eq(10)
      10.times do |i|
        expect(state).to have_key("op_#{i}")
      end
    end
  end
end
