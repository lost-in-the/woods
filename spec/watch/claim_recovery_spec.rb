# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'timeout'
require 'stringio'
require 'woods/watch/daemon'
require 'woods/watch/cli'

RSpec.describe 'Explicit managed watch claim recovery' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:messages) { StringIO.new }
  let(:cli) { Woods::Watch::CLI.new(output: messages) }

  around do |example|
    Dir.mktmpdir('woods-claim-recovery') do |directory|
      @index = directory
      @claim = File.join(directory, Woods::Watch::Daemon::CLAIM_FILENAME)
      example.run
    ensure
      stop_child
      @owner&.send(:release_claim)
    end
  end

  def start_child
    @reader, writer = IO.pipe
    @pid = Process.spawn(RbConfig.ruby, '-I', File.join(root, 'lib'), '-e', <<~RUBY, @index, out: writer)
      require 'woods/watch/daemon'
      Woods::Watch::Status.define_singleton_method(:host_identity) { 'replaced-container' }
      daemon = Woods::Watch::Daemon.new(root: ARGV.first, output_dir: ARGV.first, conservative_claims: true)
      abort 'claim unavailable' unless daemon.send(:claim_startup?)
      puts File.read(File.join(ARGV.first, Woods::Watch::Daemon::CLAIM_FILENAME))
      STDOUT.flush
      sleep 300
    RUBY
    writer.close
    @record = Timeout.timeout(5) { JSON.parse(@reader.gets) }
  end

  def stop_child
    return unless @pid

    Process.kill('KILL', @pid)
    Process.wait(@pid)
    @pid = nil
    @reader.close
  end

  def recover(token = @record.fetch('token', 'a' * 64))
    cli.run(['--recover-claim', @index, '--claim-token', token])
  end

  def lease_path
    "#{@claim}.lease"
  end

  # A claim written by a release that bound ownership to the lease's device and
  # inode, as that writer's mount view numbered them.
  # Every refusal that sends the reader to the watch guide names a heading it really has.
  def expect_existing_doc_section(message)
    sections = message.scan(%r{follow "([^"]+)" in docs/WATCH_DAEMON\.md}).flatten
    guide = File.readlines(File.join(root, 'docs/WATCH_DAEMON.md'), encoding: 'UTF-8')
    headings = guide.grep(/\A#+ /).map { |line| line.sub(/\A#+ /, '').strip }

    expect(sections).not_to be_empty
    expect(headings).to include(*sections)
  end

  def write_v1_claim(token: 'c' * 64, device: 7, inode: 9)
    File.write(lease_path, '')
    File.chmod(0o600, lease_path)
    @record = { 'pid' => 57, 'host' => 'retired-container', 'lease_version' => 1, 'token' => token,
                'lease_device' => device, 'lease_inode' => inode }
    File.write(@claim, JSON.generate(@record))
  end

  it 'publishes a token only while the actual foreign child holds its lifetime lease' do
    start_child
    expect(@record).to include('lease_version' => 2)
    expect(@record['lease_id']).to match(/\A[a-f0-9]{32}\z/)
    expect(@record).not_to include('lease_device', 'lease_inode')
    expect(@record['token']).to match(/\A[a-f0-9]{64}\z/)
    File.utime(Time.at(0), Time.at(0), @claim)
    bytes = File.binread(@claim)

    expect(recover).to eq(2)
    expect(messages.string).to include('owner lease is held')
    expect(File.binread(@claim)).to eq(bytes)
  end

  it 'explicitly clears a killed foreign child claim and admits a new managed owner' do
    start_child
    stop_child

    expect(recover).to eq(0)
    expect(File.exist?(@claim)).to be(false)
    @owner = Woods::Watch::Daemon.new(root: @index, output_dir: @index, conservative_claims: true)
    expect(@owner.send(:claim_startup?)).to be(true)
    replacement = JSON.parse(File.read(@claim))
    expect(replacement['token']).not_to eq(@record['token'])
    expect(recover).to eq(2)
    expect(JSON.parse(File.read(@claim))).to eq(replacement)
  end

  it 'refuses an old token even after a successor also stops' do
    start_child
    stop_child
    expect(recover('b' * 64)).to eq(2)
    expect(messages.string).to include('claim token changed')
    expect(JSON.parse(File.read(@claim))).to eq(@record)
  end

  it 'never removes legacy foreign claims merely because they are old' do
    File.write(@claim, JSON.generate(pid: 12, host: 'retired-container'))
    File.utime(Time.at(0), Time.at(0), @claim)
    expect(recover('a' * 64)).to eq(2)
    expect(messages.string).to include('legacy or unverifiable')
    expect(JSON.parse(File.read(@claim))).to include('host' => 'retired-container')
  end

  it 'serializes recovery against a new owner without removing its successor claim' do
    start_child
    stop_child
    recovery = Woods::Watch::ClaimLease.new(@index)
    checked = Queue.new
    release = Queue.new
    allow(recovery).to receive(:verify_lease).and_wrap_original do |original, record|
      original.call(record)
      checked << true
      release.pop
    end
    recovering = Thread.new { recovery.recover(token: @record.fetch('token')) }
    Timeout.timeout(5) { checked.pop }
    @owner = Woods::Watch::Daemon.new(root: @index, output_dir: @index, conservative_claims: true)
    expect(@owner.send(:claim_startup?)).to be(false)
    expect(JSON.parse(File.read(@claim))).to eq(@record)
    release << true
    expect(recovering.value).to eq(1) # File.unlink removed only the selected old claim.
    expect(@owner.send(:claim_startup?)).to be(true)
    successor = File.binread(@claim)
    expect(recover).to eq(2)
    expect(File.binread(@claim)).to eq(successor)
  ensure
    release << true if release
    recovering&.join(5)
  end

  it 'refuses changed bytes after selecting a claim even with a free lease' do
    start_child
    stop_child
    recovery = Woods::Watch::ClaimLease.new(@index)
    successor = @record.merge('token' => 'd' * 64)
    allow(recovery).to receive(:verify_lease).and_wrap_original do |original, record|
      original.call(record)
      File.write(@claim, JSON.generate(successor))
    end
    expect { recovery.recover(token: @record.fetch('token')) }
      .to raise_error(Woods::Watch::ClaimLease::Unavailable, /changed during recovery/)
    expect(JSON.parse(File.read(@claim))).to eq(successor)
  end

  # Moving the claim aside lets startup recreate a missing lease or rewrite a
  # replaced one's id; a lease that is not a regular file blocks startup too.
  {
    missing: 'Manual claim recovery', replaced: 'Manual claim recovery',
    symlink: 'Starting over in a new output directory', fifo: 'Starting over in a new output directory',
    directory: 'Starting over in a new output directory'
  }.each do |damage, section|
    it "refuses a #{damage} lease without replacing the inode or clearing the claim, pointing to #{section}" do
      start_child
      stop_child
      lease = "#{@claim}.lease"
      saved = "#{lease}.original"
      File.rename(lease, saved)
      case damage
      when :symlink then File.symlink(saved, lease)
      when :fifo then File.mkfifo(lease, 0o600)
      when :directory then Dir.mkdir(lease)
      when :replaced then File.write(lease, '')
      end
      bytes = File.binread(@claim)
      Timeout.timeout(2) { expect(recover).to eq(2) }
      expect(File.binread(@claim)).to eq(bytes)
      expect(File.exist?(lease)).to be(false) if damage == :missing
      expect(messages.string).to include('confirm every watcher writing this index has stopped')
      expect(messages.string).to include(%(follow "#{section}" in docs/WATCH_DAEMON.md))
      expect_existing_doc_section(messages.string)
      expect(messages.string).not_to include(@record.fetch('token'))
    end
  end

  describe 'a claim recorded through another mount view (#1078)' do
    it 'recovers a v1 claim whose recorded device and inode differ, with the exact token and a free lease' do
      write_v1_claim

      expect(recover).to eq(0)
      expect(File.exist?(@claim)).to be(false)
      expect(File.exist?(lease_path)).to be(true)
    end

    it 'recovers a v1 claim whose recorded numbers still match' do
      write_v1_claim
      stat = File.stat(lease_path)
      File.write(@claim, JSON.generate(@record.merge('lease_device' => stat.dev, 'lease_inode' => stat.ino)))

      expect(recover).to eq(0)
      expect(File.exist?(@claim)).to be(false)
    end

    it 'refuses a v1 claim with any other token' do
      write_v1_claim
      bytes = File.binread(@claim)

      expect(recover('b' * 64)).to eq(2)
      expect(messages.string).to include('claim token changed')
      expect(File.binread(@claim)).to eq(bytes)
    end

    it 'refuses a v1 claim while a live process holds its lease' do
      write_v1_claim
      holder = File.open(lease_path, File::RDWR) # rubocop:disable Style/FileOpen -- the open descriptor is the lock
      holder.flock(File::LOCK_EX)
      bytes = File.binread(@claim)

      expect(recover).to eq(2)
      expect(messages.string).to include('owner lease is held')
      expect(File.binread(@claim)).to eq(bytes)
    ensure
      holder&.close
    end

    it 'cannot tell a recreated v1 lease from a changed mount view, so the token and free lease decide' do
      write_v1_claim
      File.rename(lease_path, "#{lease_path}.original")
      File.write(lease_path, '')

      expect(recover).to eq(0)
    end

    it 'verifies a v2 lease id from a process that numbers the lease differently' do
      start_child
      stop_child
      allow_any_instance_of(File::Stat).to receive(:dev).and_return(4242)
      allow_any_instance_of(File::Stat).to receive(:ino).and_return(31_337)

      expect(recover).to eq(0)
      expect(File.exist?(@claim)).to be(false)
    end

    it 'refuses a v2 claim whose lease holds another complete id' do
      start_child
      stop_child
      File.write(lease_path, "#{'e' * 32}\n")
      bytes = File.binread(@claim)

      expect(recover).to eq(2)
      expect(messages.string).to include('owner lease was replaced')
      expect_existing_doc_section(messages.string)
      expect(File.binread(@claim)).to eq(bytes)
      expect(File.binread(lease_path)).to eq("#{'e' * 32}\n")
    end

    it 'never writes a lease id while recovering' do
      start_child
      stop_child
      File.write(lease_path, '')

      expect(recover).to eq(2)
      expect(File.binread(lease_path)).to eq('')
    end

    it 'refuses an unknown claim version' do
      start_child
      stop_child
      File.write(@claim, JSON.generate(@record.merge('lease_version' => 3)))

      expect(recover).to eq(2)
      expect(messages.string).to include('legacy or unverifiable')
    end
  end

  describe 'recovery messages (#1078)' do
    let(:token) { 'c' * 64 }

    {
      'a held lease' => [:hold_lease, 'stop that owner through its supervisor'],
      'a changed token' => [:retoken, 'another owner claimed this index'],
      'a legacy claim' => %i[legacy_claim manual_recovery],
      'a missing claim' => [:remove_claim, 'nothing to recover'],
      'a missing lease' => %i[remove_lease manual_recovery]
    }.each do |refusal, (damage, next_step)|
      it "names the next step and never prints the token for #{refusal}" do
        write_v1_claim(token: token)
        send(damage)

        expect(recover(token)).to eq(2)
        if next_step == :manual_recovery
          expect_existing_doc_section(messages.string)
        else
          expect(messages.string).to include(next_step)
        end
        expect(messages.string).not_to include(token)
      ensure
        @holder&.close
      end
    end

    it 'names where to run recovery when the sidecars cannot be opened' do
      write_v1_claim(token: token)
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(lease_path, anything, anything).and_raise(Errno::EACCES)

      expect(recover(token)).to eq(2)
      expect(messages.string).to include('run recovery inside the environment that writes this index')
      expect(messages.string).not_to include(token)
      expect(File.exist?(@claim)).to be(true)
    end

    it 'names the index to check when the index directory does not exist' do
      missing = File.join(@index, 'no-such-index')

      expect(cli.run(['--recover-claim', missing, '--claim-token', token])).to eq(2)
      expect(messages.string).to include("no index directory at #{missing}")
      expect(messages.string).to include('the exact index the application uses')
      expect(messages.string).not_to include(token)
    end

    it 'names where the token lives when the token is malformed' do
      write_v1_claim(token: token)

      expect(recover('not-a-token')).to eq(2)
      expect(messages.string).to include("copy \"token\" from #{@claim}")
    end

    def remove_claim
      File.unlink(@claim)
    end

    def remove_lease
      File.unlink(lease_path)
    end

    def hold_lease
      @holder = File.open(lease_path, File::RDWR)
      @holder.flock(File::LOCK_EX)
    end

    def retoken
      File.write(@claim, JSON.generate(@record.merge('token' => 'd' * 64)))
    end

    def legacy_claim
      File.write(@claim, JSON.generate(pid: 12, host: 'retired-container'))
    end
  end

  it 'fails closed when managed ownership locks are unsupported' do
    allow_any_instance_of(File).to receive(:flock).and_raise(Errno::ENOTSUP)
    @owner = Woods::Watch::Daemon.new(root: @index, output_dir: @index, conservative_claims: true)
    expect(@owner.send(:claim_startup?)).to be(false)
    expect(File.exist?(@claim)).to be(false)
  end

  it 'preserves the active lease inode and claim across index cleanup' do
    require 'rake'
    require 'woods/rake_helpers'
    start_child
    lease_path = "#{@claim}.lease"
    before = File.stat(lease_path).ino
    File.write(File.join(@index, 'manifest.json'), '{}')

    expect(Woods::RakeHelpers.woods_clean_index(@index, wait: 0)).to eq(:cleaned)

    expect(File.exist?(File.join(@index, 'manifest.json'))).to be(false)
    expect(File.stat(lease_path).ino).to eq(before)
    expect(JSON.parse(File.read(@claim))).to eq(@record)
    expect(recover).to eq(2)
    expect(messages.string).to include('owner lease is held')
  end
end
