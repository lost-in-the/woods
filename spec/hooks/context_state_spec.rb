# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/hooks/context_state'

RSpec.describe Woods::Hooks::ContextState do
  let(:directory) { Dir.mktmpdir('woods-context-state') }
  let(:state) { described_class.new(directory) }
  let(:result) { { root: '/app', session: 'one', identity: Digest::SHA256.hexdigest('one') } }
  after { FileUtils.remove_entry(directory) }

  it 'suppresses identical emitted evidence but allows content, generation and session changes' do
    emitted = []
    state.emit(result) { emitted << :first }
    state.emit(result) { emitted << :duplicate }
    state.emit(result.merge(identity: Digest::SHA256.hexdigest('changed'))) { emitted << :changed }
    state.emit(result.merge(session: 'two')) { emitted << :other_session }
    expect(emitted).to eq(%i[first changed other_session])
  end

  it 'does not suppress uncertain content identities or sessionless events' do
    emitted = 0
    2.times { state.emit(result.merge(identity: nil)) { emitted += 1 } }
    2.times { state.emit(result.merge(session: nil)) { emitted += 1 } }
    expect(emitted).to eq(4)
  end

  it 'bounds and prunes both sessions and per-session history' do
    40.times do |session|
      40.times do |hint|
        state.emit(result.merge(session: session.to_s, identity: Digest::SHA256.hexdigest(hint.to_s))) { nil }
      end
    end
    data = JSON.parse(File.read(File.join(directory, 'hook-context-state.json')))
    expect(data.size).to eq(32)
    expect(data.values.map(&:size).uniq).to eq([32])
    expect(JSON.generate(data).bytesize).to be <= described_class::MAX_BYTES
  end

  it 'skips a contending hint without touching the refresh queue' do
    queued = File.join(directory, 'hook-pending')
    FileUtils.mkdir_p(queued)
    File.write(File.join(queued, 'event.json'), 'untouched')
    File.open(File.join(directory, 'hook-context-state.json.lock'), 'w') do |lock|
      lock.flock(File::LOCK_EX)
      expect { |block| state.emit(result, &block) }.not_to yield_control
    end
    expect(File.read(File.join(queued, 'event.json'))).to eq('untouched')
  end

  it 'recovers malformed history and refuses symlinked state destinations' do
    path = File.join(directory, 'hook-context-state.json')
    File.write(path, '[]')
    expect { |block| state.emit(result, &block) }.to yield_control
    File.unlink(path)
    outside = File.join(directory, 'unrelated')
    File.write(outside, 'keep')
    File.symlink(outside, path)
    expect { |block| state.emit(result, &block) }.not_to yield_control
    expect(File.read(outside)).to eq('keep')
  end

  %i[symlink hardlink].each do |alias_type|
    it "preserves a pre-existing temporary #{alias_type} and its unrelated contents" do
      unrelated = File.join(directory, 'unrelated')
      File.write(unrelated, 'preserve unrelated contents')
      temporary = File.join(directory, 'hook-context-state.json.tmp')
      alias_type == :symlink ? File.symlink(unrelated, temporary) : File.link(unrelated, temporary)

      state.emit(result) { nil }

      expect(File.read(unrelated)).to eq('preserve unrelated contents')
      expect(File.exist?(temporary)).to be(true)
      expect(File.identical?(temporary, unrelated)).to be(true)
    end
  end
end
