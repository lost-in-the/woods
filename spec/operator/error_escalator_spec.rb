# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'net/http'
require 'codebase_index/operator/error_escalator'

RSpec.describe CodebaseIndex::Operator::ErrorEscalator do
  subject(:escalator) { described_class.new }

  describe '#classify' do
    context 'with transient errors' do
      it 'classifies Timeout::Error as transient' do
        result = escalator.classify(Timeout::Error.new('connection timed out'))
        expect(result[:severity]).to eq(:transient)
        expect(result[:category]).to eq('timeout')
      end

      it 'classifies Net::HTTPFatalError as transient' do
        response = Net::HTTPServiceUnavailable.new('1.1', '503', 'Service Unavailable')
        error = Net::HTTPFatalError.new('503 Service Unavailable', response)
        result = escalator.classify(error)
        expect(result[:severity]).to eq(:transient)
        expect(result[:category]).to eq('network')
      end

      it 'includes remediation for transient errors' do
        result = escalator.classify(Timeout::Error.new('timed out'))
        expect(result[:remediation]).not_to be_nil
        expect(result[:remediation]).to include('Retry')
      end
    end

    context 'with permanent errors' do
      it 'classifies NameError as permanent' do
        result = escalator.classify(NameError.new('undefined local variable'))
        expect(result[:severity]).to eq(:permanent)
        expect(result[:category]).to eq('code_error')
      end

      it 'classifies Errno::ENOENT as permanent' do
        result = escalator.classify(Errno::ENOENT.new('file not found'))
        expect(result[:severity]).to eq(:permanent)
        expect(result[:category]).to eq('missing_file')
      end

      it 'classifies JSON::ParserError as permanent' do
        result = escalator.classify(JSON::ParserError.new('unexpected token'))
        expect(result[:severity]).to eq(:permanent)
        expect(result[:category]).to eq('corrupt_data')
      end
    end

    context 'with unknown errors' do
      it 'classifies unrecognized errors as unknown' do
        result = escalator.classify(StandardError.new('something weird'))
        expect(result[:severity]).to eq(:unknown)
        expect(result[:category]).to eq('unclassified')
      end
    end

    it 'always includes error_class and message' do
      result = escalator.classify(RuntimeError.new('boom'))
      expect(result[:error_class]).to eq('RuntimeError')
      expect(result[:message]).to eq('boom')
    end
  end
end
