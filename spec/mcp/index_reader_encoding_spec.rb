# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'woods/mcp/index_reader'
require 'woods/export/typed_reader'

RSpec.describe Woods::MCP::IndexReader do
  # Release finding H1: a C/US-ASCII host locale makes bare `Pathname#read`
  # tag artifact bytes US-ASCII, so any non-ASCII byte in an index artifact
  # breaks JSON.parse with Encoding::InvalidByteSequenceError and poisons
  # string reads. These specs pin the fix: artifact reads must work under a
  # US-ASCII default external encoding.
  #
  # Exercise both legacy flat indexes and the published generation layout.

  let(:branch) { 'feature/café' }
  let(:source) { 'class Café; def dessert; "crème brûlée"; end; end' }
  let(:payload_name) { nil }

  let(:index_dir) do
    Dir.mktmpdir('woods-encoding-index').tap do |dir|
      payload = payload_name ? File.join(dir, payload_name) : dir
      FileUtils.mkdir_p(payload)
      write_manifest(payload)
      write_model_index(payload)
      write_summary(payload)
      File.binwrite(File.join(payload, 'dependency_graph.json'), JSON.generate(nodes: {}, edges: {}, reverse: {}))
      Woods::Generation.new(output_dir: dir).bump!(payload: payload_name) if payload_name
    end
  end

  let(:reader) { described_class.new(index_dir) }
  let(:unit_path) { File.join(index_dir, payload_name.to_s, 'models', unit_filename('Café')) }

  after { FileUtils.remove_entry(index_dir) }

  shared_examples 'UTF-8 unit reads' do
    [nil, 'model'].each do |type|
      it "preserves the complete unit in #{type ? 'typed' : 'untyped'} lookup under US-ASCII" do
        unit = in_us_ascii_locale { reader.find_unit('Café', type: type) }

        expect(unit).to include('identifier' => 'Café', 'type' => 'model', 'source_code' => source)
        expect(unit.fetch('source_code').encoding).to eq(Encoding::UTF_8)
      end
    end

    it 'enumerates complete typed units under US-ASCII' do
      units = in_us_ascii_locale { reader.each_unit.to_a }

      expect(units).to contain_exactly(include('identifier' => 'Café', 'type' => 'model', 'source_code' => source))
    end

    it 'searches non-ASCII source under US-ASCII' do
      result = in_us_ascii_locale { reader.search('brûlée', fields: ['source_code']) }

      expect(result[:results]).to contain_exactly(identifier: 'Café', type: 'model', match_field: 'source_code')
    end

    it 'searches identifiers and source within package and path scopes under US-ASCII' do
      in_us_ascii_locale do
        scope = { packages: ['packs/café'], source_paths: ['app/models'] }
        identifiers = reader.search('Café', **scope)
        sources = reader.search('brûlée', fields: ['source_code'], **scope)

        expect(identifiers[:results]).to contain_exactly(identifier: 'Café', type: 'model', match_field: 'identifier')
        expect(sources[:results]).to contain_exactly(identifier: 'Café', type: 'model', match_field: 'source_code')
        expect(sources[:applied_scope]).to include(eligible_units: 1, packages: ['packs/café'])
      end
    end

    it 'provides complete UTF-8 units to typed export consumers under US-ASCII' do
      in_us_ascii_locale do
        export = Woods::Export::TypedReader.new(reader)

        expect(export.find('Café', 'model')).to include('source_code' => source)
        expect(export.all).to contain_exactly(include('identifier' => 'Café', 'source_code' => source))
      end
    end

    %i[typed bulk].each do |operation|
      it "rejects invalid UTF-8 during #{operation} reads without replacing bytes" do
        File.binwrite(unit_path, File.binread(unit_path).sub('brûlée'.b, "\xFF".b))

        in_us_ascii_locale do
          expect { operation == :typed ? reader.find_unit('Café', type: 'model') : reader.each_unit.to_a }
            .to raise_error(JSON::ParserError, /UTF-8/)
        end
      end
    end
  end

  context 'with a legacy flat index' do
    include_examples 'UTF-8 unit reads'
  end

  context 'with a published generation' do
    let(:payload_name) { 'payloads/utf8' }

    include_examples 'UTF-8 unit reads'

    it 'rejects a unit replaced with a symlink before the checked open' do
      path = unit_path
      allow(File).to receive(:open).and_wrap_original do |original, candidate, *args, &block|
        if candidate.to_s == path
          File.rename(path, "#{path}.original")
          File.symlink("#{path}.original", path)
        end
        original.call(candidate, *args, &block)
      end

      expect { in_us_ascii_locale { reader.find_unit('Café', type: 'model') } }.to raise_error(Errno::ELOOP)
    end

    it 'rejects a unit replaced with a FIFO before opening without blocking' do
      path = unit_path
      allow(File).to receive(:open).and_wrap_original do |original, candidate, *args, &block|
        if candidate.to_s == path
          File.unlink(path)
          File.mkfifo(path)
        end
        original.call(candidate, *args, &block)
      end

      expect do
        Timeout.timeout(2) { in_us_ascii_locale { reader.each_unit.to_a } }
      end.to raise_error(IOError, /non-regular unit file/)
    end

    it 'boots lexical MCP and returns non-ASCII source through packaged stdio under a C locale' do
      metadata = {
        'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
        'io.modelcontextprotocol/clientInfo' => { name: 'encoding-spec', version: '1' },
        'io.modelcontextprotocol/clientCapabilities' => {}
      }
      calls = [
        ['lookup', { identifier: 'Café', type: 'model' }],
        ['codebase_retrieve', { query: 'brûlée' }]
      ]
      requests = calls.each_with_index.map do |(name, arguments), i|
        JSON.generate(jsonrpc: '2.0', id: i + 1, method: 'tools/call',
                      params: { name: name, arguments: arguments, _meta: metadata })
      end.join("\n")
      env = { 'LANG' => 'C', 'LC_ALL' => 'C', 'WOODS_RETRIEVAL_MODE' => 'lexical',
              'MCP_PROTOCOL_VERSION' => nil, 'OPENAI_API_KEY' => nil, 'WOODS_SNAPSHOTS' => nil }
      executable = File.expand_path('../../exe/woods-mcp', __dir__)
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, '-EUS-ASCII', '-rbundler/setup',
                                              executable, index_dir, stdin_data: "#{requests}\n")

      expect(status).to be_success, stderr.force_encoding(Encoding::UTF_8)
      responses = stdout.force_encoding(Encoding::UTF_8).lines.map { |line| JSON.parse(line) }
      expect(responses.map { |response| response.fetch('id') }).to eq([1, 2])
      responses.each do |response|
        result = response.fetch('result')
        expect(result.fetch('isError')).to be(false)
        expect(result.fetch('content').map { |item| item.fetch('text') }.join).to include('Café', 'crème brûlée')
      end
    end
  end

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
    File.binwrite(File.join(dir, 'manifest.json'), manifest)
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
    File.binwrite(File.join(models_dir, '_index.json'), index)
    unit = JSON.generate(
      'identifier' => 'Café',
      'type' => 'model',
      'file_path' => 'app/models/café.rb',
      'source_code' => source,
      'metadata' => { 'package' => 'packs/café' }
    )
    File.binwrite(File.join(models_dir, unit_filename('Café')), unit)
  end

  def write_summary(dir)
    File.binwrite(File.join(dir, 'SUMMARY.md'), <<~SUMMARY)
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
