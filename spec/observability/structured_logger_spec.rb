# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'json'
require 'codebase_index/observability/structured_logger'

RSpec.describe CodebaseIndex::Observability::StructuredLogger do
  let(:output) { StringIO.new }
  let(:logger) { described_class.new(output: output) }

  describe '#info' do
    it 'writes a JSON line with level info' do
      logger.info('extraction.complete', units: 42)

      line = JSON.parse(output.string)
      expect(line['level']).to eq('info')
      expect(line['event']).to eq('extraction.complete')
      expect(line['units']).to eq(42)
    end

    it 'includes a timestamp' do
      logger.info('test.event')

      line = JSON.parse(output.string)
      expect(line).to have_key('timestamp')
      expect { Time.parse(line['timestamp']) }.not_to raise_error
    end
  end

  describe '#warn' do
    it 'writes a JSON line with level warn' do
      logger.warn('extraction.slow', duration_ms: 5000)

      line = JSON.parse(output.string)
      expect(line['level']).to eq('warn')
      expect(line['event']).to eq('extraction.slow')
      expect(line['duration_ms']).to eq(5000)
    end
  end

  describe '#error' do
    it 'writes a JSON line with level error' do
      logger.error('extraction.failed', message: 'Connection refused')

      line = JSON.parse(output.string)
      expect(line['level']).to eq('error')
      expect(line['event']).to eq('extraction.failed')
      expect(line['message']).to eq('Connection refused')
    end
  end

  describe '#debug' do
    it 'writes a JSON line with level debug' do
      logger.debug('cache.hit', key: 'User')

      line = JSON.parse(output.string)
      expect(line['level']).to eq('debug')
      expect(line['event']).to eq('cache.hit')
      expect(line['key']).to eq('User')
    end
  end

  describe 'output format' do
    it 'writes one line per log entry' do
      logger.info('event.one')
      logger.info('event.two')

      lines = output.string.strip.split("\n")
      expect(lines.size).to eq(2)
    end

    it 'each line is valid JSON' do
      logger.info('event.one', a: 1)
      logger.warn('event.two', b: 2)

      output.string.strip.split("\n").each do |line|
        expect { JSON.parse(line) }.not_to raise_error
      end
    end

    it 'defaults output to $stderr' do
      default_logger = described_class.new
      expect(default_logger).to be_a(described_class)
    end
  end
end
