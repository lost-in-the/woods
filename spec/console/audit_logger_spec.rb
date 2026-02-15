# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/audit_logger'
require 'tmpdir'
require 'json'

RSpec.describe CodebaseIndex::Console::AuditLogger do
  let(:log_dir) { Dir.mktmpdir }
  let(:log_path) { File.join(log_dir, 'audit.jsonl') }

  subject(:logger) { described_class.new(path: log_path) }

  after { FileUtils.rm_rf(log_dir) }

  describe '#log' do
    it 'writes a JSONL entry' do
      logger.log(tool: 'console_eval', params: { code: '1+1' }, confirmed: true, result_summary: 'ok')

      lines = File.readlines(log_path)
      expect(lines.size).to eq(1)

      entry = JSON.parse(lines.first)
      expect(entry['tool']).to eq('console_eval')
      expect(entry['params']).to eq({ 'code' => '1+1' })
      expect(entry['confirmed']).to be true
      expect(entry['result_summary']).to eq('ok')
    end

    it 'includes a timestamp' do
      logger.log(tool: 'console_sql', params: { sql: 'SELECT 1' }, confirmed: false, result_summary: 'denied')

      entry = JSON.parse(File.readlines(log_path).first)
      expect(entry).to have_key('timestamp')
      # Timestamp should be ISO 8601 format
      expect(entry['timestamp']).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it 'appends multiple entries' do
      logger.log(tool: 'console_eval', params: {}, confirmed: true, result_summary: 'ok')
      logger.log(tool: 'console_sql', params: {}, confirmed: true, result_summary: 'ok')

      lines = File.readlines(log_path)
      expect(lines.size).to eq(2)
    end

    it 'creates parent directories if needed' do
      nested_path = File.join(log_dir, 'deep', 'nested', 'audit.jsonl')
      nested_logger = described_class.new(path: nested_path)
      nested_logger.log(tool: 'test', params: {}, confirmed: true, result_summary: 'ok')

      expect(File.exist?(nested_path)).to be true
    end
  end

  describe '#entries' do
    it 'returns all logged entries as hashes' do
      logger.log(tool: 'a', params: {}, confirmed: true, result_summary: 'ok')
      logger.log(tool: 'b', params: {}, confirmed: false, result_summary: 'denied')

      entries = logger.entries
      expect(entries.size).to eq(2)
      expect(entries.first['tool']).to eq('a')
      expect(entries.last['tool']).to eq('b')
    end

    it 'returns empty array when no log file exists' do
      fresh_logger = described_class.new(path: File.join(log_dir, 'nonexistent.jsonl'))
      expect(fresh_logger.entries).to eq([])
    end
  end

  describe '#size' do
    it 'returns the number of entries' do
      expect(logger.size).to eq(0)
      logger.log(tool: 'x', params: {}, confirmed: true, result_summary: 'ok')
      expect(logger.size).to eq(1)
    end
  end
end
