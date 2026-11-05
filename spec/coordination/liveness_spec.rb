# frozen_string_literal: true

require 'spec_helper'
require 'woods/coordination/liveness'

RSpec.describe Woods::Coordination::Liveness do
  let(:pid) { 4242 }
  let(:proc_status) { "/proc/#{pid}/status" }

  def stub_signal(outcome)
    allow(Process).to receive(:kill).and_call_original
    if outcome == :ok
      allow(Process).to receive(:kill).with(0, pid).and_return(1)
    else
      allow(Process).to receive(:kill).with(0, pid).and_raise(outcome)
    end
  end

  def stub_proc(state)
    allow(File).to receive(:binread).and_call_original
    if state.is_a?(Class)
      allow(File).to receive(:binread).with(proc_status).and_raise(state)
    else
      allow(File).to receive(:binread).with(proc_status).and_return("Name:\truby\nState:\t#{state}\n".b)
    end
  end

  # The whole rule, one row per combination of the evidence it reads.
  describe '.check truth table (Linux)' do
    before { stub_const('RUBY_PLATFORM', 'x86_64-linux') }

    [
      [:ok,          'S (sleeping)', :alive],
      [:ok,          'R (running)',  :alive],
      [:ok,          'Z (zombie)',   :zombie],
      [:ok,          Errno::EACCES,  :alive],
      [:ok,          Errno::ENOENT,  :alive],
      [Errno::EPERM, 'S (sleeping)', :alive],
      [Errno::EPERM, 'Z (zombie)',   :zombie],
      [Errno::EPERM, Errno::EACCES,  :unknown],
      [Errno::EPERM, Errno::ENOENT,  :unknown],
      [Errno::ESRCH, 'S (sleeping)', :dead]
    ].each do |signal, proc_state, expected|
      it "answers #{expected} for signal 0 #{signal == :ok ? 'ok' : signal.name} with /proc #{proc_state}" do
        stub_signal(signal)
        stub_proc(proc_state)

        expect(described_class.check(pid)).to eq(expected)
      end
    end

    it 'never reads /proc for a pid signal 0 cannot find' do
      stub_signal(Errno::ESRCH)
      allow(File).to receive(:binread).and_call_original

      expect(described_class.check(pid)).to eq(:dead)
      expect(File).not_to have_received(:binread).with(proc_status)
    end
  end

  describe '.check off Linux' do
    before do
      stub_const('RUBY_PLATFORM', 'arm64-darwin24')
      allow(File).to receive(:binread).and_call_original
    end

    it 'reads a signalled pid as alive without /proc' do
      stub_signal(:ok)

      expect(described_class.check(pid)).to eq(:alive)
      expect(File).not_to have_received(:binread).with(proc_status)
    end

    it 'reads EPERM as unknown, because nothing can rule out a zombie' do
      stub_signal(Errno::EPERM)

      expect(described_class.check(pid)).to eq(:unknown)
    end
  end

  describe '.check host placement' do
    before { allow(Process).to receive(:kill).and_call_original }

    it 'checks a pid recorded on this host' do
      expect(described_class.check(Process.pid, host: 'here', local_host: 'here')).to eq(:alive)
    end

    it 'never signals a pid recorded on another host' do
      expect(described_class.check(Process.pid, host: 'there', local_host: 'here')).to eq(:unknown)
      expect(Process).not_to have_received(:kill)
    end

    it 'reads a record that names no host as unknown' do
      expect(described_class.check(Process.pid, host: nil, local_host: 'here')).to eq(:unknown)
    end

    it 'reads any record as unknown when this host has no identity' do
      expect(described_class.check(Process.pid, host: 'unknown', local_host: 'unknown')).to eq(:unknown)
    end

    [nil, 0, -1, 'unknown', 12.5].each do |bad|
      it "reads #{bad.inspect} as unknown without signalling" do
        expect(described_class.check(bad)).to eq(:unknown)
        expect(Process).not_to have_received(:kill)
      end
    end
  end

  describe 'real processes' do
    it 'reads this process as alive' do
      expect(described_class.check(Process.pid)).to eq(:alive)
    end

    it 'reads a reaped child as dead', if: Process.respond_to?(:fork) do
      child = fork { exit!(0) }
      Process.wait(child)

      expect(described_class.check(child)).to eq(:dead)
    end

    it 'reads a real unreaped child as a zombie', if: UnreapedChild::SUPPORTED do
      UnreapedChild.with_zombie do |zombie|
        expect(described_class.check(zombie)).to eq(:zombie)
      end
    end
  end

  describe '.gone?' do
    it 'is true only for evidence the process finished' do
      expect(described_class::STATES.select { |state| described_class.gone?(state) }).to eq(%i[dead zombie])
    end
  end
end
