# frozen_string_literal: true

require 'spec_helper'
require_relative '../../script/verification/journey'

RSpec.describe WoodsVerification::Journey do
  describe '.verify_observation!' do
    let(:observation) { { 'live' => 'after', 'indexed' => 'after', 'full' => 'after', 'generation' => 2 } }

    it 'accepts the expected runtime fact and publication generation' do
      expect { described_class.verify_observation!(observation, 'after', 2) }.not_to raise_error
    end

    it 'rejects a stale publication even when the fixture exits successfully' do
      observation['indexed'] = 'before'
      expect { described_class.verify_observation!(observation, 'after', 2) }.to raise_error(WoodsVerification::EvidenceError)
    end

    it 'rejects a no-op generation' do
      observation['generation'] = 1
      expect { described_class.verify_observation!(observation, 'after', 2) }.to raise_error(WoodsVerification::EvidenceError)
    end

    it 'rejects missing evidence instead of interpreting it as a pass' do
      expect { described_class.verify_observation!({}, 'after', 2) }.to raise_error(WoodsVerification::EvidenceError)
    end

    it 'rejects an oracle that disagrees with the live runtime' do
      observation['full'] = 'before'
      expect { described_class.verify_observation!(observation, 'after', 2) }.to raise_error(WoodsVerification::EvidenceError)
    end
  end
end

RSpec.describe WoodsVerification::Command do
  around do |example|
    Dir.mktmpdir('verification-spec-') do |directory|
      @directory = directory
      example.run
    end
  end

  let(:commands) { [] }
  let(:runner) { described_class.new(root: @directory, evidence: @directory, commands: commands, timeout: 10) }

  it 'reads real command evidence and records its successful exit' do
    expect(runner.run('ok', [RbConfig.ruby, '-e', 'puts %q({"work":1})'])).to eq('work' => 1)
    expect(commands.last[:exit_status]).to eq(0)
    expect(commands.last[:elapsed_seconds]).to be >= 0
  end

  it 'refuses a successful command with no observation' do
    expect { runner.run('empty', [RbConfig.ruby, '-e', 'exit 0']) }.to raise_error(WoodsVerification::HarnessError)
  end

  it 'refuses failed commands even if they print a plausible observation' do
    expect { runner.run('failed', [RbConfig.ruby, '-e', 'puts %q({"work":1}); exit 1']) }
      .to raise_error(WoodsVerification::EvidenceError, /exited 1/)
  end

  it 'bounds and reaps a stalled child' do
    runner = described_class.new(root: @directory, evidence: @directory, commands: commands, timeout: 0.1)
    expect { runner.run('stalled', [RbConfig.ruby, '-e', 'sleep 10']) }
      .to raise_error(WoodsVerification::EvidenceError, /exceeded/)
    expect(commands.last[:timed_out]).to be(true)
    expect(commands.last[:elapsed_seconds]).to be >= 0.1
  end

  it 'kills and reaps its child when interrupted' do
    child = nil
    allow(Process).to(receive(:spawn).and_wrap_original { |method, *args| child = method.call(*args) })
    allow(Process).to receive(:wait2).and_raise(Interrupt)
    expect { runner.run('interrupted', [RbConfig.ruby, '-e', 'sleep 10']) }.to raise_error(Interrupt)
    expect { Process.kill(0, child) }.to raise_error(Errno::ESRCH)
    expect { Process.wait(child) }.to raise_error(Errno::ECHILD)
    expect(commands.last[:interrupted]).to be(true)
  end
end

RSpec.describe 'Verification dependency identity' do
  it 'includes ignored effective lock bytes in the candidate identity' do
    Dir.mktmpdir('verification-lock-') do |directory|
      lock = File.join(directory, 'Gemfile.lock')
      File.write(lock, 'first')
      journey = WoodsVerification::Journey.new(root: directory)
      allow(journey).to receive(:git).with('ls-files', '-z', '--cached', '--others',
                                           '--exclude-standard').and_return('')
      allow(journey).to receive(:git).with('rev-parse', 'HEAD').and_return('candidate')
      allow(journey).to receive(:git).with('status', '--porcelain').and_return('')
      allow(Bundler).to receive(:default_lockfile).and_return(Pathname.new(lock))
      before = journey.send(:identity)
      File.write(lock, 'second')
      expect(journey.send(:identity)).not_to eq(before)
    end
  end
end

RSpec.describe 'Verification diagnostic receipts' do
  around do |example|
    Dir.mktmpdir('verification-receipt-') do |directory|
      @journey = WoodsVerification::Journey.new(root: directory)
      example.run
    end
  end

  before do
    allow(@journey).to receive(:identity).and_return(head: 'candidate')
    allow(@journey).to receive(:doctor)
  end

  def receipt
    JSON.parse(File.read(File.join(@journey.evidence, 'receipt.json')))
  end

  it 'retains the earlier and failing parsed observations before an assertion aborts the journey' do
    before = { 'live' => 'before', 'indexed' => 'before', 'full' => 'before', 'generation' => 1 }
    stale = { 'live' => 'after', 'indexed' => 'before', 'full' => 'after', 'generation' => 1 }
    allow(@journey).to receive(:execute).and_return(before, stale)
    expect(@journey.run).to eq(1)
    expect(receipt).to include('status' => 'failed_assertion', 'observations' => [before, stale])
  end

  it 'classifies known prerequisite failures separately from assertions' do
    allow(@journey).to receive(:doctor).and_raise(WoodsVerification::EnvironmentBlocker, 'missing Rails appraisal')
    expect(@journey.run).to eq(1)
    expect(receipt).to include('status' => 'blocked_environment', 'error' => /missing Rails appraisal/)
  end

  it 'preserves unexpected harness failures without labeling them product regressions' do
    allow(@journey).to receive(:drive).and_raise(TypeError, 'invalid harness input')
    expect(@journey.run).to eq(1)
    expect(receipt).to include('status' => 'failed_harness', 'error' => /TypeError/)
  end

  it 'checkpoints a successful observation before starting the next phase' do
    before = { 'live' => 'before', 'indexed' => 'before', 'full' => 'before', 'generation' => 1 }
    allow(@journey).to receive(:execute) do |name, _command|
      next before if name == 'before'

      expect(receipt.fetch('observations')).to eq([before])
      raise TypeError, 'second phase did not complete'
    end
    expect(@journey.run).to eq(1)
    expect(receipt.fetch('observations')).to eq([before])
  end

  it 'invalidates an assertion result if the candidate changed before failure' do
    allow(@journey).to receive(:identity).and_return({ head: 'start' }, { head: 'end' })
    allow(@journey).to receive(:drive).and_raise(WoodsVerification::AssertionFailure, 'queue differs')
    expect(@journey.run).to eq(1)
    expect(receipt).to include('status' => 'blocked_environment', 'ending_candidate' => { 'head' => 'end' })
    expect(receipt.fetch('provenance')).to include('valid' => false, 'reason' => 'identity_changed')
    expect(receipt.fetch('diagnostic_outcome')).to include('status' => 'failed_assertion', 'error' => /queue differs/)
  end

  it 'retains the original failure when ending identity cannot be read' do
    reads = 0
    allow(@journey).to receive(:identity) do
      reads += 1
      raise IOError, 'identity unavailable' if reads > 1

      { head: 'start' }
    end
    allow(@journey).to receive(:drive).and_raise(WoodsVerification::AssertionFailure, 'queue differs')
    expect(@journey.run).to eq(1)
    expect(receipt.fetch('status')).to eq('blocked_environment')
    expect(receipt.fetch('provenance')).to include('valid' => false, 'reason' => 'identity_lookup_failed',
                                                   'error' => /identity unavailable/)
    expect(receipt.fetch('diagnostic_outcome')).to include('status' => 'failed_assertion', 'error' => /queue differs/)
  end

  it 'preserves interruption while flagging changed provenance' do
    allow(@journey).to receive(:identity).and_return({ head: 'start' }, { head: 'end' })
    allow(@journey).to receive(:drive).and_raise(Interrupt)
    expect(@journey.run).to eq(130)
    expect(receipt.fetch('status')).to eq('interrupted')
    expect(receipt.fetch('provenance')).to include('valid' => false)
  end

  it 'does not return success if provenance is invalidated during finalization' do
    allow(@journey).to receive(:drive)
    allow(@journey).to receive(:identity).and_return({ head: 'start' }, { head: 'start' }, { head: 'end' })
    expect(@journey.run).to eq(1)
    expect(receipt.fetch('diagnostic_outcome')).to include('status' => 'passed_scoped_journey')
    expect(receipt.fetch('status')).to eq('blocked_environment')
  end
end
