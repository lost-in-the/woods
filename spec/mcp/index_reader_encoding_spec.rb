# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'woods/mcp/index_reader'

RSpec.describe Woods::MCP::IndexReader do
  # Release finding H1: a C/US-ASCII host locale makes bare `Pathname#read`
  # tag artifact bytes US-ASCII, so any non-ASCII byte in an index artifact
  # breaks JSON.parse with Encoding::InvalidByteSequenceError and poisons
  # string reads. These specs pin the fix: artifact reads must work under a
  # US-ASCII default external encoding.
  #
  # The fixtures here are intentionally minimal flat indexes (manifest.json
  # at the index root), which is the layout current_payload_dir falls back
  # to and the shape spec/fixtures/woods uses.

  let(:branch) { 'feature/café' }

  let(:index_dir) do
    Dir.mktmpdir('woods-encoding-index').tap do |dir|
      write_manifest(dir)
      write_model_index(dir)
      write_summary(dir)
    end
  end

  let(:reader) { described_class.new(index_dir) }

  describe 'JSON artifact reads' do
    it 'parses manifest.json and _index.json under a US-ASCII default external encoding' do
      unit = nil
      manifest_branch = nil

      in_us_ascii_locale do
        manifest_branch = reader.manifest['git_branch']
        unit = reader.find_unit('Café')
      end

      expect(manifest_branch).to eq('feature/café')
      expect(unit).not_to be_nil
      expect(unit['identifier']).to eq('Café')
      expect(unit['file_path']).to eq('app/models/café.rb')
    end

    it 'lets no Encoding::InvalidByteSequenceError escape the read paths' do
      escaped = nil

      in_us_ascii_locale do
        escaped = [
          capture_invalid_byte_sequence { reader.manifest },
          capture_invalid_byte_sequence { reader.find_unit('Café') }
        ].compact
      end

      expect(escaped).to be_empty
    end
  end

  describe '#summary' do
    it 'returns usable UTF-8 content under a US-ASCII default external encoding' do
      summary = nil

      in_us_ascii_locale do
        summary = reader.summary
      end

      expect(summary).to be_valid_encoding
      expect(summary.encoding).to eq(Encoding::UTF_8)
      expect(summary).to include('Café review')
    end
  end

  private

  # Emulates a C-locale host: bare reads tag artifact bytes US-ASCII.
  # Restores the previous default external encoding in ensure.
  def in_us_ascii_locale
    previous = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII
    yield
  ensure
    Encoding.default_external = previous
  end

  # Captures an escaping InvalidByteSequenceError (or returns nil) so the
  # no-escape expectation names the exact class without RSpec's
  # not_to raise_error(SpecificErrorClass) false-positive risk.
  def capture_invalid_byte_sequence
    yield
    nil
  rescue Encoding::InvalidByteSequenceError => e
    e
  end

  def write_manifest(dir)
    manifest = JSON.pretty_generate(
      'extracted_at' => '2026-08-20T12:00:00Z',
      'rails_version' => '8.1.2',
      'ruby_version' => '4.0.1',
      'counts' => { 'models' => 1 },
      'total_units' => 1,
      'total_chunks' => 0,
      'git_sha' => 'abc1234',
      'git_branch' => branch
    )
    File.write(File.join(dir, 'manifest.json'), manifest)
  end

  def write_model_index(dir)
    models_dir = File.join(dir, 'models')
    FileUtils.mkdir_p(models_dir)
    index = JSON.generate([{
                            'identifier' => 'Café',
                            'file_path' => 'app/models/café.rb',
                            'namespace' => nil,
                            'estimated_tokens' => 100,
                            'chunk_count' => 1
                          }])
    File.write(File.join(models_dir, '_index.json'), index)
    unit = JSON.generate(
      'identifier' => 'Café',
      'type' => 'model',
      'file_path' => 'app/models/café.rb'
    )
    File.write(File.join(models_dir, unit_filename('Café')), unit)
  end

  def write_summary(dir)
    File.write(File.join(dir, 'SUMMARY.md'), <<~SUMMARY)
      # Codebase Index Summary

      ## Café review
      Indexes a model with a non-ASCII identifier: Café.
    SUMMARY
  end

  # Mirrors IndexReader identifier_map naming (base mangled to [a-zA-Z0-9_-],
  # then an 8-char SHA-256 prefix) so find_unit resolves the unit file.
  def unit_filename(identifier)
    base = identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
    "#{base}_#{Digest::SHA256.hexdigest(identifier)[0, 8]}.json"
  end
end
