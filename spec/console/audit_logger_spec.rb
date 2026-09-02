# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/audit_logger'
require 'tmpdir'
require 'json'

RSpec.describe Woods::Console::AuditLogger do
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

  describe 'control-character sanitization' do
    it 'strips embedded newlines from a hostile result_summary' do
      logger.log(
        tool: 'console_eval',
        params: {},
        confirmed: true,
        result_summary: "ok\nINJECTED:{\"tool\":\"fake\",\"confirmed\":true}"
      )

      lines = File.readlines(log_path)
      expect(lines.size).to eq(1)
      entry = JSON.parse(lines.first)
      expect(entry['result_summary']).not_to include("\n")
      expect(entry['result_summary']).to eq('okINJECTED:{"tool":"fake","confirmed":true}')
    end

    it 'strips NUL and control bytes from params keys' do
      logger.log(
        tool: 'console_sql',
        params: { "a\x00b" => "v\x01w" },
        confirmed: true,
        result_summary: 'ok'
      )
      entry = JSON.parse(File.readlines(log_path).first)
      expect(entry['params']).to eq({ 'ab' => 'vw' })
    end

    it 'preserves horizontal tab (legitimate whitespace)' do
      logger.log(
        tool: 'console_eval',
        params: { code: "a\tb" },
        confirmed: true,
        result_summary: 'ok'
      )
      entry = JSON.parse(File.readlines(log_path).first)
      expect(entry['params']['code']).to eq("a\tb")
    end
  end

  # ── Redaction runs before truncation (CON-5) ────────────────────────────
  #
  # `truncate_value` cuts a >16 KiB field at MAX_FIELD_CHARS. When redaction
  # ran on the already-truncated string, a credential positioned across the
  # cut was split: the scanner's word-boundary/length-anchored patterns no
  # longer matched the surviving prefix, and cleartext `sk_live_4eC39…` landed
  # in the JSONL — a plaintext secret at rest in the one artifact that is
  # supposed to be safe for audit review.
  describe 'a credential straddling the truncation boundary' do
    # Documented fixture — Stripe's own documentation example key.
    let(:secret) { 'sk_live_4eC39HqLyjWDarjtT1zdp7dc' }

    # Build a payload whose secret begins `head_chars` before the truncation
    # cut, so `head_chars` of it survive and the rest is discarded. The
    # surrounding spaces are what the scanner's word-boundary anchors need —
    # the same shape a pasted credential has in a real `console_eval` payload.
    def straddling_payload(secret, head_chars: 20)
      "#{'x' * (described_class::MAX_FIELD_CHARS - head_chars - 1)} #{secret} #{'y' * 100}"
    end

    it 'redacts a param secret instead of logging its truncated prefix' do
      logger.log(tool: 'console_eval', params: { code: straddling_payload(secret) },
                 confirmed: true, result_summary: 'ok')

      line = File.read(log_path, encoding: 'UTF-8')
      expect(line).to include('[REDACTED]')
      expect(line).not_to include('sk_live_')
    end

    it 'redacts a result_summary secret instead of logging its truncated prefix' do
      logger.log(tool: 'console_eval', params: { code: '1+1' },
                 confirmed: true, result_summary: straddling_payload(secret))

      line = File.read(log_path, encoding: 'UTF-8')
      expect(line).to include('[REDACTED]')
      expect(line).not_to include('sk_live_')
    end

    it 'leaks no prefix at any offset across the boundary' do
      (1..31).each do |head_chars|
        FileUtils.rm_f(log_path)
        logger.log(tool: 'console_eval', params: { code: straddling_payload(secret, head_chars: head_chars) },
                   confirmed: true, result_summary: 'ok')

        expect(File.read(log_path, encoding: 'UTF-8')).not_to include('sk_live_'), "leaked at offset #{head_chars}"
      end
    end

    it 'still bounds the logged field so the disk cap survives redaction' do
      logger.log(tool: 'console_eval', params: { code: straddling_payload(secret) },
                 confirmed: true, result_summary: 'ok')

      entry = JSON.parse(File.read(log_path, encoding: 'UTF-8'))
      expect(entry['params']['code']).to include('[truncated')
      expect(entry['params']['code'].length).to be <= described_class::MAX_FIELD_CHARS + 100
    end
  end
end
