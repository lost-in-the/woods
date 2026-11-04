# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/watch/supervision_status'

RSpec.describe Woods::Watch::SupervisionStatus do
  let(:index) { Dir.mktmpdir('woods supervisors') }
  let(:token) { 'a' * 32 }
  let(:attempt) { 'b' * 32 }
  let(:status) { described_class.new(index: index, token: token) }
  let(:path) { File.join(index, described_class::DIRECTORY, "#{token}.json") }
  let(:fields) { { state: 'ready', reason: 'reconciled', child_pid: Process.pid, attempt: attempt } }

  after { FileUtils.rm_rf(index) }

  it 'separates recorded state from owner liveness and bounds returned records' do
    status.write(**fields)
    record = described_class.read(index)[:records].first
    expect(record).to include('state' => 'ready', 'alive' => true, 'launcher' => token)
    status.write(**fields, state: 'stopped', reason: 'owner_stopped')
    expect(described_class.read(index)[:records].first['alive']).to be(false)
  end

  it 'does not overwrite a record belonging to another process namespace' do
    status.write(**fields)
    previous = JSON.parse(File.read(path)).merge('host' => 'foreign')
    File.write(path, JSON.generate(previous))

    expect { status.write(**fields) }.to raise_error(ArgumentError, /another owner/)
    expect(JSON.parse(File.read(path))['host']).to eq('foreign')
  end

  it 'ignores oversized files and symlinks without reading their targets' do
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, 'x' * (described_class::MAX_BYTES + 1))
    expect(described_class.read(index)[:records]).to be_empty
    File.unlink(path)
    File.symlink('/dev/zero', path)
    expect(described_class.read(index)[:records]).to be_empty
  end

  it 'prunes an expired stopped record while preserving another live owner' do
    old = described_class.new(index: index, token: 'c' * 32)
    old.write(**fields, state: 'stopped', reason: 'owner_stopped')
    old_path = File.join(index, described_class::DIRECTORY, "#{'c' * 32}.json")
    data = JSON.parse(File.read(old_path)).merge('updated_at' => (Time.now - 60).utc.iso8601)
    File.write(old_path, JSON.generate(data))

    status.write(**fields)
    expect(File.exist?(old_path)).to be(false)
    expect(described_class.read(index)[:records].map { |record| record['launcher'] }).to eq([token])
  end

  it 'reports truncation when the bounded directory scan cannot inspect every entry' do
    FileUtils.mkdir_p(File.dirname(path))
    (described_class::MAX_SCAN + 1).times { |number| File.write(File.join(File.dirname(path), "unused-#{number}"), '') }
    expect(described_class.read(index)).to include(records: [], truncated: true)
  end

  it 'correlates a live launcher with its actual daemon child, not merely a ready label' do
    status.write(**fields)
    expect(described_class.read(index)[:records].first['active_child']).to be(false)
    Woods::Watch::Status.new(output_dir: index).write(state: :running)
    expect(described_class.read(index)[:records].first['active_child']).to be(true)
  end

  it 'preserves a still-live owner whose heartbeat is stale' do
    other = described_class.new(index: index, token: 'c' * 32)
    other.write(**fields)
    other_path = File.join(index, described_class::DIRECTORY, "#{'c' * 32}.json")
    record = JSON.parse(File.read(other_path)).merge('updated_at' => (Time.now - 60).utc.iso8601)
    File.write(other_path, JSON.generate(record))

    status.write(**fields)
    expect(File.exist?(other_path)).to be(true)
  end

  # A launcher killed in a container whose PID 1 never reaps stays a zombie,
  # and signal 0 still answers for it (#1002). These records name a pid
  # directly, so each case writes the record by hand.
  describe 'owner liveness' do
    let(:other_token) { 'c' * 32 }
    let(:other_path) { File.join(index, described_class::DIRECTORY, "#{other_token}.json") }

    def write_owner(pid:, age: 0, host: Woods::Watch::Status.host_identity)
      FileUtils.mkdir_p(File.dirname(other_path))
      File.write(other_path, JSON.generate(
                               version: 1, launcher: other_token, pid: pid, host: host, state: 'ready',
                               updated_at: (Time.now - age).utc.iso8601
                             ))
    end

    def owner
      described_class.read(index)[:records].find { |record| record['launcher'] == other_token }
    end

    it 'reads a live same-host owner as alive' do
      write_owner(pid: Process.pid)

      expect(owner['alive']).to be(true)
    end

    context 'with a real unreaped owner', if: UnreapedChild::SUPPORTED do
      it 'reads the owner as not alive' do
        UnreapedChild.with_zombie do |zombie|
          write_owner(pid: zombie)

          expect(owner['alive']).to be(false)
        end
      end

      it 'prunes its expired record' do
        UnreapedChild.with_zombie do |zombie|
          write_owner(pid: zombie, age: 60)

          status.write(**fields)
          expect(File.exist?(other_path)).to be(false)
        end
      end

      it 'keeps the expired record of a zombie pid recorded on another host' do
        UnreapedChild.with_zombie do |zombie|
          write_owner(pid: zombie, age: 60, host: 'another-host')

          status.write(**fields)
          expect(File.exist?(other_path)).to be(true)
        end
      end
    end

    # EPERM with no readable /proc status: unknown, which is not enough to
    # prune another owner's record.
    it 'keeps the expired record of an owner whose liveness is unknown', if: Process.respond_to?(:fork) do
      pid = fork { exit!(0) }
      Process.wait(pid)
      write_owner(pid: pid, age: 60)
      allow(Process).to receive(:kill).and_call_original
      allow(Process).to receive(:kill).with(0, pid).and_raise(Errno::EPERM)
      allow(File).to receive(:binread).and_call_original
      allow(File).to receive(:binread).with("/proc/#{pid}/status").and_raise(Errno::EACCES)

      status.write(**fields)
      expect(File.exist?(other_path)).to be(true)
    end
  end
end
