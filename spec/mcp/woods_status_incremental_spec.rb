# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/server'
require 'woods/mcp/index_reader'
require 'woods/payload_store'
require 'woods/generation'
require 'woods/source_references/cache'
require 'woods/source_references/caller_policy'
require 'tmpdir'

RSpec.describe 'woods_status incremental readiness' do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('WOODS_NO_UPDATE_CHECK').and_return(nil)
  end

  def build_index(root)
    cache_class = Woods::SourceReferences::Cache
    dir = Woods::PayloadStore.new(root).create(1)
    dir.mkpath
    dir.join('manifest.json').write(JSON.generate('woods_version' => Woods::VERSION, 'counts' => { 'model' => 0 },
                                                  'total_units' => 0))
    dir.join('dependency_graph.json').write(JSON.generate(nodes: {}, edges: {}, reverse: {}, file_map: {},
                                                          type_index: {}))
    cache_class.write(dir.join(cache_class::FILE_NAME),
                      'version' => cache_class::VERSION, 'callers' => Woods::SourceReferences::CallerPolicy.new({}).to_h,
                      'files' => {}, 'owners' => [])
    Woods::Generation.new(output_dir: root).bump!(reason: 'full', payload: Woods::PayloadStore.name_for(1))
    dir.join(cache_class::FILE_NAME)
  end

  def incremental_for(root)
    reader = Woods::MCP::IndexReader.new(root)
    Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: root)[:index][:incremental]
  end

  it 'reports ready, then needs full extraction for a malformed cache, then ready again' do
    Dir.mktmpdir do |root|
      cache_path = build_index(root)
      good = cache_path.binread
      expect(incremental_for(root)).to eq(ready: true, status: 'ready')

      cache_path.write('not json')
      result = incremental_for(root)
      expect(result[:ready]).to be(false)
      expect(result[:status]).to match(/\Aneeds full extraction \(.*source reference cache/)

      cache_path.binwrite(good)
      expect(incremental_for(root)).to eq(ready: true, status: 'ready')
    end
  end

  it 'reports a flat index as needing a full extraction without making the index not ready' do
    flat = File.expand_path('../fixtures/woods', __dir__)
    reader = Woods::MCP::IndexReader.new(flat)
    status = Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: flat)

    expect(status[:index][:incremental][:status]).to match(/needs full extraction \(.*legacy flat index/)
    expect(status[:ready]).to be(true)
  end
end
