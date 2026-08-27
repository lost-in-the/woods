# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'json'
require 'woods/observability/structured_logger'

RSpec.describe 'Observability + Health Integration', :integration do
  # ── StructuredLogger ────────────────────────────────────────────

  describe 'StructuredLogger' do
    let(:output) { StringIO.new }
    let(:logger) { Woods::Observability::StructuredLogger.new(output: output) }

    it 'writes JSON log lines' do
      logger.info('extraction.complete', units: 42)

      output.rewind
      line = output.readline
      entry = JSON.parse(line)

      expect(entry['level']).to eq('info')
      expect(entry['event']).to eq('extraction.complete')
      expect(entry['units']).to eq(42)
      expect(entry).to have_key('timestamp')
    end

    it 'supports all log levels' do
      logger.debug('debug.event', data: 'test')
      logger.info('info.event', data: 'test')
      logger.warn('warn.event', data: 'test')
      logger.error('error.event', data: 'test')

      output.rewind
      lines = output.readlines
      levels = lines.map { |l| JSON.parse(l)['level'] }

      expect(levels).to eq(%w[debug info warn error])
    end

    it 'includes timestamps in ISO8601 format' do
      logger.info('test.event')

      output.rewind
      entry = JSON.parse(output.readline)

      expect { Time.parse(entry['timestamp']) }.not_to raise_error
    end

    it 'includes arbitrary structured data' do
      logger.info('embedding.batch', count: 10, duration_ms: 150, model: 'nomic')

      output.rewind
      entry = JSON.parse(output.readline)

      expect(entry['count']).to eq(10)
      expect(entry['duration_ms']).to eq(150)
      expect(entry['model']).to eq('nomic')
    end

    it 'writes one line per log entry' do
      logger.info('event1')
      logger.info('event2')
      logger.info('event3')

      output.rewind
      lines = output.readlines
      expect(lines.size).to eq(3)

      # Each line should be valid JSON
      lines.each do |line|
        expect { JSON.parse(line) }.not_to raise_error
      end
    end
  end
end
