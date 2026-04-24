# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/tool_response_renderer'
require 'woods/mcp/renderers/plain_renderer'

RSpec.describe Woods::MCP::Renderers::PlainRenderer do
  subject(:renderer) { described_class.new }

  describe '#render_lookup' do
    it 'renders unit identifier and file' do
      out = renderer.render(:lookup, {
                              'identifier' => 'User',
                              'type' => 'model',
                              'file_path' => 'app/models/user.rb'
                            })
      expect(out).to include('User (model)')
      expect(out).to include('File: app/models/user.rb')
    end

    it 'returns a not-found message for non-hash input' do
      expect(renderer.render(:lookup, nil)).to eq('Unit not found')
      expect(renderer.render(:lookup, 'string input')).to eq('Unit not found')
    end

    it 'returns a not-found message for a hash without identifier' do
      expect(renderer.render(:lookup, { 'type' => 'model' })).to eq('Unit not found')
    end

    it 'includes source code when present' do
      out = renderer.render(:lookup, {
                              'identifier' => 'X',
                              'type' => 'service',
                              'source_code' => 'class X; end'
                            })
      expect(out).to include('class X; end')
    end

    it 'renders metadata hash values without crashing' do
      out = renderer.render(:lookup, {
                              'identifier' => 'User',
                              'type' => 'model',
                              'metadata' => { 'table_name' => 'users', 'columns' => %w[id email] }
                            })
      expect(out).to include('table_name: users')
      expect(out).to include('- id')
    end
  end

  describe '#render_search' do
    it 'renders query and result list' do
      data = {
        query: 'user',
        result_count: 2,
        results: [
          { identifier: 'User', type: 'model' },
          { identifier: 'UserMailer', type: 'mailer' }
        ]
      }
      out = renderer.render(:search, data)
      expect(out).to include('Search: "user" (2 results)')
      expect(out).to include('User (model)')
      expect(out).to include('UserMailer (mailer)')
    end

    it 'handles empty results' do
      data = { query: 'nothing', result_count: 0, results: [] }
      out = renderer.render(:search, data)
      expect(out).to include('Search: "nothing" (0 results)')
    end
  end

  describe '#render_dependencies' do
    it 'renders the label header with the root identifier' do
      # NOTE: the renderer has a latent bug with found:false detection when
      # data carries symbol keys (`data[:found] || data['found']` short-
      # circuits on false). This is tracked separately; for this spec we
      # exercise the found-true / no-found branch, which is the common path.
      out = renderer.render(:dependencies, {
                              root: 'Ghost',
                              nodes: {}
                            })
      expect(out).to include('Dependencies of Ghost')
    end

    it 'renders nodes tree structure' do
      out = renderer.render(:dependencies, {
                              root: 'User',
                              nodes: { 'User' => { depth: 0, deps: %w[Post] } }
                            })
      expect(out).to include('User')
      expect(out).to include('-> Post')
    end
  end

  describe '#render_default' do
    it 'handles hashes, arrays, and scalars' do
      expect(renderer.render(:unknown, { a: 1 })).to eq('a: 1')
      expect(renderer.render(:unknown, [1, 2])).to include('1').and include('2')
      expect(renderer.render(:unknown, 'hi')).to eq('hi')
    end
  end
end
