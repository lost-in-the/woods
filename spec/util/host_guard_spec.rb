# frozen_string_literal: true

require 'spec_helper'
require 'woods/util/host_guard'

RSpec.describe Woods::Util::HostGuard do
  describe '.canonicalize' do
    it 'downcases the host' do
      expect(described_class.canonicalize('LOCALHOST')).to eq('localhost')
    end

    it 'strips a trailing port' do
      expect(described_class.canonicalize('example.com:3000')).to eq('example.com')
    end

    it 'strips the FQDN trailing dot' do
      expect(described_class.canonicalize('example.com.')).to eq('example.com')
    end

    it 'strips IPv6 brackets' do
      expect(described_class.canonicalize('[::1]')).to eq('::1')
    end

    it 'strips port AND trailing dot in one pass' do
      expect(described_class.canonicalize('localhost.:3000')).to eq('localhost')
    end
  end

  describe '.suspicious_numeric_host?' do
    it 'rejects hex IPv4 (0x7f000001)' do
      expect(described_class.suspicious_numeric_host?('0x7f000001')).to be(true)
    end

    it 'rejects bare-integer IPv4 (2130706433)' do
      expect(described_class.suspicious_numeric_host?('2130706433')).to be(true)
    end

    it 'rejects bare-octal IPv4 (017700000001)' do
      expect(described_class.suspicious_numeric_host?('017700000001')).to be(true)
    end

    it 'rejects leading-zero octet (0177.0.0.1)' do
      expect(described_class.suspicious_numeric_host?('0177.0.0.1')).to be(true)
    end

    it 'rejects short-form two-part (127.1)' do
      expect(described_class.suspicious_numeric_host?('127.1')).to be(true)
    end

    it 'rejects short-form three-part (127.0.1)' do
      expect(described_class.suspicious_numeric_host?('127.0.1')).to be(true)
    end

    it 'rejects mixed-radix (0x7f.0.0.1)' do
      expect(described_class.suspicious_numeric_host?('0x7f.0.0.1')).to be(true)
    end

    it 'rejects a hex octet anywhere in the four-part form (10.0.0.0x1)' do
      expect(described_class.suspicious_numeric_host?('10.0.0.0x1')).to be(true)
    end

    it 'accepts standard dotted-decimal IPv4' do
      expect(described_class.suspicious_numeric_host?('192.0.2.1')).to be(false)
      expect(described_class.suspicious_numeric_host?('127.0.0.1')).to be(false)
      expect(described_class.suspicious_numeric_host?('10.0.0.5')).to be(false)
    end

    it 'accepts a plain hostname' do
      expect(described_class.suspicious_numeric_host?('example.com')).to be(false)
      expect(described_class.suspicious_numeric_host?('host1')).to be(false)
    end

    it 'accepts standard IPv6' do
      expect(described_class.suspicious_numeric_host?('::1')).to be(false)
      expect(described_class.suspicious_numeric_host?('2001:db8::1')).to be(false)
    end

    it 'accepts the "0.0.0.0" literal (covered by PRIVATE_IP_RANGES downstream)' do
      # 0.0.0.0 is a valid dotted form; the private-range check catches it.
      # HostGuard only flags NON-canonical notations.
      expect(described_class.suspicious_numeric_host?('0.0.0.0')).to be(false)
    end
  end
end
