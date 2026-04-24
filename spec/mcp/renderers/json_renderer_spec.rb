# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/tool_response_renderer'
require 'woods/mcp/renderers/json_renderer'

RSpec.describe Woods::MCP::Renderers::JsonRenderer do
  subject(:renderer) { described_class.new }

  describe '#render (default path)' do
    it 'pretty-prints a nested hash' do
      out = renderer.render(:anything, { a: 1, b: { c: 2 } })
      expect(out).to include('"a": 1')
      expect(out).to include('"c": 2')
      # pretty-printed JSON has newlines between top-level keys
      expect(out.lines.size).to be > 1
    end

    it 'handles arrays' do
      out = renderer.render(:anything, [1, 2, 3])
      expect(JSON.parse(out)).to eq([1, 2, 3])
    end

    it 'handles nil gracefully' do
      expect(renderer.render(:anything, nil)).to eq('null')
    end

    it 'handles empty hash' do
      expect(renderer.render(:anything, {})).to eq('{}')
    end

    it 'handles empty array' do
      expect(renderer.render(:anything, [])).to eq('[]')
    end
  end
end
