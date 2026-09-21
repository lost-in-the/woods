# frozen_string_literal: true

require 'woods/extractor'
require 'woods/mcp/server'

module ValidationPublicationProbe
  def self.lookup(directory)
    server = Woods::MCP::Server.build(index_dir: directory, response_format: :json, warmup: false)
    request = { jsonrpc: '2.0', id: 1, method: 'tools/call',
                params: { name: 'lookup', arguments: { identifier: 'ValidationItem', type: 'model' } } }
    result = JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
    raise 'model lookup failed' if result['isError']

    result.fetch('structuredContent').fetch('data').except('file_path', 'extracted_at')
  end

  def self.call(root, model_path)
    Woods.configuration.concurrent_extraction = false
    initial = File.join(root, 'tmp/woods-incremental')
    Woods::Extractor.new(output_dir: initial).extract_all
    before = lookup(initial)
    source = File.read(model_path).sub("'before'", "'changed'")
    File.write(model_path, source)
    # Reload the edited runtime class and its validators from the application file.
    ValidationItem.clear_validators!
    load model_path
    Woods::Extractor.new(output_dir: initial).extract_changed(['app/models/validation_item.rb'])
    oracle = File.join(root, 'tmp/woods-full')
    Woods::Extractor.new(output_dir: oracle).extract_all
    { before_hash: before.fetch('source_hash'), incremental: lookup(initial), full: lookup(oracle) }
  end
end
