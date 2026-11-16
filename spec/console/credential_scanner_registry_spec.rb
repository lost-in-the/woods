# frozen_string_literal: true

require 'spec_helper'
require 'weakref'
require 'open3'
require 'woods/console/credential_scanner'
require 'woods/console/credential_scanner_registry'

RSpec.describe Woods::Console::CredentialScannerRegistry do
  subject(:registry) { described_class.new }

  let(:old_index) { Woods::Console::CredentialIndex.new(secrets: ['old-synthetic-secret']) }
  let(:new_index) { Woods::Console::CredentialIndex.new(secrets: ['new-synthetic-secret']) }

  it 'does not build an index without live scanners' do
    expect(registry.rebuild { raise 'must not build' }).to be_nil
  end

  it 'replaces all live indexes only after the build succeeds' do
    scanners = Array.new(2) do
      registry.register { Woods::Console::CredentialScanner.new(secret_index: old_index) }
    end

    expect { registry.rebuild { raise IOError, 'unreadable credential snapshot' } }.to raise_error(IOError)
    scanners.each { |scanner| expect(scanner.scan('old-synthetic-secret').first).to eq('[REDACTED:credential]') }
    expect(registry.rebuild { new_index }).to equal(new_index)
    scanners.each { |scanner| expect(scanner.scan('new-synthetic-secret').first).to eq('[REDACTED:credential]') }
  end

  def register_unowned_scanner(registry)
    # A returned Ruby stack frame can still conservatively root the scanner
    # on older Rubies. End its owning thread before asking GC to collect it.
    Thread.new do
      WeakRef.new(registry.register { Woods::Console::CredentialScanner.new })
    end.value
  end

  it 'does not retain abandoned scanners or their transports' do
    reference = register_unowned_scanner(registry)
    5.times do
      GC.start(full_mark: true, immediate_sweep: true)
      break unless reference.weakref_alive?
    end

    expect(reference.weakref_alive?).to be_falsey
    expect(registry.rebuild { raise 'must not build' }).to be_nil
  end

  it 'keeps the live scanner snapshot alive while rebuilding allocates and collects' do
    owners = [registry.register { Woods::Console::CredentialScanner.new(secret_index: old_index) }]
    reference = WeakRef.new(owners.first)
    survivor = nil

    registry.rebuild do
      owners.clear
      GC.start(full_mark: true, immediate_sweep: true)
      expect(reference.weakref_alive?).to be_truthy
      survivor = reference.__getobj__
      new_index
    end

    expect(survivor.scan('new-synthetic-secret').first).to eq('[REDACTED:credential]')
  end

  it 'refreshes live scanners safely while garbage collection reclaims abandoned scanners' do
    fixture = File.expand_path('../fixtures/credential_registry_gc.rb', __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, fixture)

    expect(status).to be_success, "#{stdout}\n#{stderr}"
    expect(stdout).to eq("live scanners refreshed\n")
  end
end

RSpec.describe Woods::Console::CredentialScanner, 'rotation during a response scan' do
  it 'holds one index for every nested field even when replacement happens while matching' do
    index = Class.new(Woods::Console::CredentialIndex) do
      attr_accessor :on_match

      def match?(value)
        on_match.call
        super
      end
    end.new(secrets: ['synthetic-matching-secret'])
    scanner = described_class.new(secret_index: index)
    index.on_match = -> { scanner.replace_index!(Woods::Console::CredentialIndex.new(secrets: [])) }
    input = { 'synthetic-matching-secret' => ['synthetic-matching-secret', { value: 'synthetic-matching-secret' }] }

    output, counts = scanner.scan(input)

    expect(output).to eq('[REDACTED:credential]' => ['[REDACTED:credential]', { value: '[REDACTED:credential]' }])
    expect(counts[:credential_index]).to eq(3)
    expect(scanner.scan('synthetic-matching-secret').first).to eq('synthetic-matching-secret')
  end
end
