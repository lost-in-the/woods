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

  it 'publishes a token only while the actual foreign child holds its lifetime lease' do
    start_child
    expect(@record).to include('lease_version' => 1)
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

  %i[missing symlink fifo replaced].each do |damage|
    it "refuses a #{damage} lease without replacing the inode or clearing the claim" do
      start_child
      stop_child
      lease = "#{@claim}.lease"
      saved = "#{lease}.original"
      File.rename(lease, saved)
      case damage
      when :symlink then File.symlink(saved, lease)
      when :fifo then File.mkfifo(lease, 0o600)
      when :replaced then File.write(lease, '')
      end
      bytes = File.binread(@claim)
      Timeout.timeout(2) { expect(recover).to eq(2) }
      expect(File.binread(@claim)).to eq(bytes)
      expect(File.exist?(lease)).to be(false) if damage == :missing
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
