# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
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

  it 'reads the id through the descriptor that holds the lock' do
    lease = acquired
    id = lease.fields[:lease_id]
    File.rename(@lease_path, "#{@lease_path}.moved")
    File.write(@lease_path, "#{'e' * 32}\n")

    expect(lease.fields[:lease_id]).to eq(id)
  end
end
