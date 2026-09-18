# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'tmpdir'
require 'fileutils'
require 'timeout'
require 'woods/mcp/server'
require 'woods/mcp/published_lexical_retriever'
require 'woods/filename_utils'

RSpec.describe 'Published compact evidence tools' do
  include Woods::FilenameUtils

  let(:index_dir) { Dir.mktmpdir('woods-source-evidence') }
  let(:source) do
    prefix = (1..40).map { |i| "def unrelated_#{i}; #{'nil; ' * 25}end\n" }.join
    "class Invoice\n#{prefix}def refund(payment)\n payment.reverse!\nend\nend\n"
  end

  before do
    Woods.configuration = Woods::Configuration.new
    File.write(File.join(index_dir, 'manifest.json'), '{}')
    publish('Invoice', 'model', source)
  end
  after { FileUtils.remove_entry(index_dir) }

  def publish(identifier, type, source)
    dir = Woods::MCP::IndexReader::UNIT_TYPES_BY_DIR.find { |_, types| types.include?(type) }.first
    directory = File.join(index_dir, dir)
    FileUtils.mkdir_p(directory)
    unit = { identifier: identifier, type: type, file_path: 'app/models/invoice.rb', source_code: source }
    File.write(File.join(directory, collision_safe_filename(identifier)), JSON.generate(unit))
    File.write(File.join(directory, '_index.json'), JSON.generate([{ identifier: identifier }]))
  end

  def call_tool(name, **args)
    retriever = Woods::MCP::PublishedLexicalRetriever.new(index_dir: index_dir)
    server = Woods::MCP::Server.build(index_dir: index_dir, retriever: retriever, warmup: false, response_format: :json)
    raw = server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                                           params: { name: name, arguments: args }))
    response = JSON.parse(raw, symbolize_names: true)
    expect(response).not_to have_key(:error)
    response.fetch(:result)
  end

  it 'passes the original retrieval query and returns typed compact evidence inside the closed schema' do
    result = call_tool('codebase_retrieve', query: 'refund payment', evidence: 'compact', budget: 450)
    expect(result[:isError]).not_to be(true)
    text = result[:content].first[:text]
    expect(text).to include("def refund(payment)\n payment.reverse!\nend")
    expect(text.length).to be <= 1800
    data = result[:structuredContent][:data][:sources].first[:evidence]
    expect(data[:owner]).to eq(identifier: 'Invoice', type: 'model')
    expect(data[:generation_status]).to eq('unavailable')
  end

  it 'distinguishes typed collisions and follows a full-evidence SHA guard without changing full lookup' do
    publish('Invoice', 'service', 'class Invoice; def service_call; end; end')
    result = call_tool('lookup', identifier: 'Invoice', type: 'model', evidence: 'compact', query: 'refund',
                                 budget: 400)
    evidence = result[:structuredContent][:data][:evidence]
    pointer = evidence[:full_evidence].dup
    tool = pointer.delete(:tool)
    full = call_tool(tool, **pointer)
    expect(JSON.parse(full[:content].first[:text])['source_code']).to eq(source)
    publish('Invoice', 'model', 'class Invoice; def changed; end; end')
    changed = call_tool(tool, **pointer)
    expect(changed[:isError]).to be(true)
    expect(changed[:_meta]).to include(error_code: 'stale_index', argument: 'source_sha256')
  end

  it 'uses actual mixed-bucket types when resolving full evidence' do
    publish('Gem::Thing', 'gem_source', 'class Gem::Thing; end')
    result = call_tool('lookup', identifier: 'Gem::Thing', type: 'gem_source')
    expect(JSON.parse(result[:content].first[:text])['type']).to eq('gem_source')
    expect(call_tool('lookup', identifier: 'Gem::Thing', type: 'rails_source')[:isError]).to be(true)
  end

  it 'refuses incompatible outline/full controls rather than silently ignoring them' do
    [{ evidence: 'outline', include_source: false }, { evidence: 'compact', sections: ['metadata'] },
     { evidence: 'full', query: 'refund' }, { evidence: 'full', budget: 200 }].each do |options|
      result = call_tool('lookup', identifier: 'Invoice', **options)
      expect(result[:isError]).to be(true)
      expect(result[:_meta]).to include(error_code: 'unsupported_argument', argument: 'evidence')
    end
  end

  it 'advertises the additive controls while keeping omitted and explicit full retrieval identical' do
    omitted = call_tool('codebase_retrieve', query: 'refund', budget: 400)
    explicit = call_tool('codebase_retrieve', query: 'refund', budget: 400, evidence: 'full')
    expect(explicit).to eq(omitted)
  end
  it 'refuses a symlinked typed directory before opening an outside unit' do
    original = File.join(index_dir, 'models')
    outside = Dir.mktmpdir('woods-evidence-outside')
    FileUtils.cp_r(Dir.glob(File.join(original, '*')), outside)
    FileUtils.remove_entry(original)
    File.symlink(outside, original)
    reader = Woods::MCP::IndexReader.new(index_dir)
    expect { reader.find_unit('Invoice', type: 'model') }.to raise_error(IOError, /symlink unit directory/)
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end
  it 'holds the server pin through lookup read, SHA validation and compact generation attribution' do
    File.write(File.join(index_dir, 'generation.json'), JSON.generate(number: 1))
    server = Woods::MCP::Server.build(index_dir: index_dir, warmup: false, response_format: :json)
    reader = server.instance_variable_get(:@woods_index_reader)
    reloaded = Queue.new
    original = reader.method(:find_unit)
    marker_path = File.join(index_dir, 'generation.json')
    reload_thread = nil
    reader.define_singleton_method(:find_unit) do |identifier, **options|
      result = original.call(identifier, **options)
      File.write(marker_path, JSON.generate(number: 2))
      reload_thread = Thread.new do
        reader.with_exclusive_reload { reloaded << true }
      end
      Timeout.timeout(5) { Thread.pass until reader.instance_variable_get(:@exclusive_waiters).positive? }
      raise 'reload completed inside lookup' unless reloaded.empty?

      result
    end
    request = JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                            params: { name: 'lookup', arguments: { identifier: 'Invoice', type: 'model',
                                                                   evidence: 'compact', query: 'refund', budget: 500,
                                                                   source_sha256: Digest::SHA256.hexdigest(source) } })
    result = JSON.parse(server.handle_json(request))
    expect(result.dig('result', 'structuredContent', 'data', 'evidence', 'generation')).to eq(1)
    Timeout.timeout(5) { reload_thread.join }
    expect(reader.loaded_generation).to eq(2)
  ensure
    reload_thread&.join(5)
  end
end
