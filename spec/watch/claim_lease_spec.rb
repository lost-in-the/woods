# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'shellwords'
require 'json'
require 'rbconfig'
require 'woods/watch/claim_lease'

RSpec.describe Woods::Watch::ClaimLease do
  around do |example|
    Dir.mktmpdir('woods-claim-lease') do |directory|
      @index = directory
      @lease_path = File.join(directory, "#{described_class::CLAIM}.lease")
      example.run
    ensure
      @leases&.each(&:close)
    end
  end

  def acquired
    lease = described_class.new(@index)
    (@leases ||= []) << lease
    lease.acquire
    lease
  end

  it 'records a random lease id written into the lease file, not its device or inode' do
    fields = acquired.fields

    expect(fields).to include(lease_version: 2, lease_id: match(/\A[a-f0-9]{32}\z/))
    expect(fields).not_to include(:lease_device, :lease_inode)
    expect(fields[:lease_id]).not_to eq(fields[:token][0, 32])
    expect(File.binread(@lease_path)).to eq("#{fields[:lease_id]}\n")
  end

  it 'keeps a complete lease id across owners' do
    first = acquired
    id = first.fields[:lease_id]
    first.close

    expect(acquired.fields[:lease_id]).to eq(id)
  end

  {
    'an empty lease' => '',
    'a partial id' => 'abc123',
    'a full id without its terminating newline' => 'f' * 32,
    'an over-long body' => "#{'f' * 32}\n#{'f' * 32}\n"
  }.each do |interrupted, body|
    it "writes a fresh id in place over #{interrupted}" do
      File.write(@lease_path, body)
      File.chmod(0o600, @lease_path)
      inode = File.stat(@lease_path).ino

      id = acquired.fields[:lease_id]

      expect(id).to match(/\A[a-f0-9]{32}\z/)
      expect(File.binread(@lease_path)).to eq("#{id}\n")
      expect(File.stat(@lease_path).ino).to eq(inode)
    end
  end

  it 'recovers on the next start when writing the id fails partway' do
    interrupt = true
    allow_any_instance_of(File).to receive(:pwrite).and_wrap_original do |original, bytes, offset|
      next original.call(bytes, offset) unless interrupt

      interrupt = false
      original.call(bytes[0, 10], offset)
      raise Errno::ENOSPC
    end
    expect { described_class.new(@index).acquire }.to raise_error(Errno::ENOSPC)
    expect(File.binread(@lease_path).bytesize).to eq(10)

    id = acquired.fields[:lease_id]

    expect(File.binread(@lease_path)).to eq("#{id}\n")
  end

  it 'prints a recovery command that a shell splits back into the exact index' do
    index = '/tmp/my app/woods'
    command = described_class.recovery_command(index)

    expect(command).to end_with("--claim-token <token from #{index}/watch_claim.json>")
    pasted = Shellwords.split(command.sub(/<token from .*>\z/, 'c' * 64))
    expect(pasted).to eq(['woods-watch', '--recover-claim', index, '--claim-token', 'c' * 64])
  end

  describe '#retire_stopped' do
    let(:host) { 'this-host' }
    let(:pid) { 4242 }
    let(:claim) { File.join(@index, described_class::CLAIM) }

    # A claim that would be retired: this host, this pid, version 2, naming the
    # free lease. Each refusal changes exactly one of these.
    def write_claim(**changes)
      owner = acquired
      record = { 'pid' => pid, 'host' => host, 'lease_version' => 2, 'token' => 'c' * 64,
                 'lease_id' => owner.fields[:lease_id] }.merge(changes.transform_keys(&:to_s))
      owner.close
      File.write(claim, JSON.generate(record))
      File.binread(claim)
    end

    def retire(&gone)
      gone ||= proc { true }
      described_class.new(@index).retire_stopped(pid: pid, host: host, &gone)
    end

    def expect_claim_kept(bytes)
      expect(File.binread(claim)).to eq(bytes)
      expect { acquired }.not_to raise_error
    end

    it 'retires a claim naming the stopped watcher, keeps both sidecars and frees the lease' do
      write_claim

      expect(retire).to be(true)
      expect(File.exist?(claim)).to be(false)
      expect(File.exist?(@lease_path)).to be(true)
      expect(File.exist?("#{claim}.lock")).to be(true)
      expect { acquired }.not_to raise_error
    end

    it 'leaves a claim recorded on another host, without asking about its process group' do
      bytes = write_claim(host: 'retired-container')
      asked = false

      expect(retire { asked = true }).to be(false)
      expect(asked).to be(false)
      expect_claim_kept(bytes)
    end

    it 'leaves a claim naming another pid' do
      bytes = write_claim(pid: pid + 1)

      expect(retire).to be(false)
      expect_claim_kept(bytes)
    end

    it 'leaves a claim whose lease lock a live process holds' do
      bytes = write_claim
      reader, writer = IO.pipe
      holder = Process.spawn(RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), '-e', <<~RUBY, @index,
        require 'woods/watch/claim_lease'
        Woods::Watch::ClaimLease.new(ARGV.first).acquire(create: false)
        puts 'held'
        STDOUT.flush
        sleep 30
      RUBY
                             out: writer)
      writer.close
      expect(reader.gets).to eq("held\n")

      expect { retire }.to raise_error(described_class::Unavailable, /owner lease is held/)
      expect(File.binread(claim)).to eq(bytes)
    ensure
      Process.kill('KILL', holder) if holder
      Process.wait(holder) if holder
      reader&.close
    end

    it 'leaves a claim naming a different lease id' do
      bytes = write_claim(lease_id: 'e' * 32)

      expect { retire }.to raise_error(described_class::Unavailable) { |error|
        expect(error.message).to include('owner lease was replaced')
        expect(error.message).not_to include('c' * 64)
      }
      expect_claim_kept(bytes)
    end

    it 'leaves a claim while the watcher process group is still present' do
      bytes = write_claim

      expect { retire { false } }.to raise_error(described_class::Unavailable, /pid #{pid} still has a live process/)
      expect_claim_kept(bytes)
    end

    it 'leaves a claim replaced between its check and the unlink' do
      write_claim
      replacement = JSON.generate(pid: pid, host: host, lease_version: 2, token: 'd' * 64, lease_id: 'f' * 32)

      expect(retire { File.write(claim, replacement) }).to be(false)
      expect(File.binread(claim)).to eq(replacement)
    end

    it 'leaves a version 1 claim, which names no lease id' do
      bytes = write_claim(lease_version: 1, lease_id: nil)

      expect(retire).to be(false)
      expect_claim_kept(bytes)
    end

    it 'has nothing to do when the claim is already gone' do
      expect(retire).to be(false)
      expect(File.exist?(claim)).to be(false)
    end
  end

  it 'reads the id through the descriptor that holds the lock' do
    lease = acquired
    id = lease.fields[:lease_id]
    File.rename(@lease_path, "#{@lease_path}.moved")
    File.write(@lease_path, "#{'e' * 32}\n")

    expect(lease.fields[:lease_id]).to eq(id)
  end
end
