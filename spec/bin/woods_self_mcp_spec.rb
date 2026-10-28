# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tmpdir'
require 'woods/gem_mapper'

# bin/woods-self-mcp is the .mcp.json entry that gives agents working on this
# repository Woods' own static map (#926). An MCP client reads stdout as the
# protocol stream, so nothing else may reach it.
RSpec.describe 'bin/woods-self-mcp' do
  let(:launcher) { File.expand_path('../../bin/woods-self-mcp', __dir__) }

  def requests(*messages)
    messages.map { |message| "#{JSON.generate(message.merge(jsonrpc: '2.0'))}\n" }.join
  end

  it 'serves an existing map over stdio with only protocol messages on stdout' do
    Dir.mktmpdir('woods-self-mcp') do |dir|
      source_root = File.join(dir, 'source')
      FileUtils.mkdir_p(File.join(source_root, 'lib/woods'))
      File.write(File.join(source_root, 'lib/woods.rb'), <<~RUBY)
        module Woods
          class Store; end
          class Runner
            def run
              Store.new
            end
          end
        end
      RUBY
      map = File.join(dir, 'map')
      Woods::GemMapper.new(root: source_root, output_dir: map).map!

      input = requests(
        { id: 1, method: 'initialize',
          params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'spec', version: '0' } } },
        { method: 'notifications/initialized' },
        { id: 2, method: 'tools/call', params: { name: 'dependents', arguments: { identifier: 'Woods::Store' } } }
      )
      env = { 'WOODS_SELF_MAP_OUTPUT' => map, 'WOODS_SELF_MAP_REFRESH' => '0' }
      stdout, stderr, = Open3.capture3(env, launcher, stdin_data: input)

      messages = stdout.lines.map { |line| JSON.parse(line) }
      expect(messages.map { |message| message['id'] }).to eq([1, 2]), stderr
      expect(messages.first.dig('result', 'serverInfo')).to be_a(Hash)
      expect(messages.last.dig('result', 'content', 0, 'text')).to include('Woods::Runner#run')
    end
  end
end
