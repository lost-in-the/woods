# frozen_string_literal: true

require 'woods/extractor'
require 'woods/mcp/server'

module MailerPublicationProbe
  def self.lookup(directory)
    server = Woods::MCP::Server.build(index_dir: directory, response_format: :json, warmup: false)
    request = { jsonrpc: '2.0', id: 1, method: 'tools/call',
                params: { name: 'lookup', arguments: { identifier: 'StableMailer', type: 'mailer' } } }
    result = JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
    raise 'mailer lookup failed' if result['isError']

    result.fetch('structuredContent').fetch('data').except('file_path', 'extracted_at')
  end

  def self.call(root, mailer_path)
    Woods.configuration.concurrent_extraction = false
    initial = File.join(root, 'tmp/woods-incremental')
    Woods::Extractor.new(output_dir: initial).extract_all
    before = lookup(initial)
    source = File.read(mailer_path).sub('def alpha; end', 'def alpha; :changed; end')
    File.write(mailer_path, source)
    line = source.lines.index { |text| text.include?('def alpha;') } + 1
    # Retain the edited application's source coordinates for action chunk extraction.
    StableMailer.class_eval('def alpha; :changed; end', mailer_path, line) # rubocop:disable Style/EvalWithLocation
    Woods::Extractor.new(output_dir: initial).extract_changed(['app/mailers/stable_mailer.rb'])
    oracle = File.join(root, 'tmp/woods-full')
    Woods::Extractor.new(output_dir: oracle).extract_all
    { before_hash: before.fetch('source_hash'), incremental: lookup(initial), full: lookup(oracle) }
  end
end
