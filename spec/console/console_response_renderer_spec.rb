# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/console_response_renderer'

RSpec.describe CodebaseIndex::Console::ConsoleResponseRenderer do
  let(:renderer) { described_class.new }

  describe '#render_default' do
    it 'renders Array<Hash> as a Markdown table' do
      data = [{ 'name' => 'Alice', 'role' => 'admin' }, { 'name' => 'Bob', 'role' => 'user' }]
      result = renderer.render_default(data)
      expect(result).to include('| name | role |')
      expect(result).to include('| --- | --- |')
      expect(result).to include('| Alice | admin |')
      expect(result).to include('| Bob | user |')
    end

    it 'renders single Hash as key-value bullet list' do
      data = { 'status' => 'ok', 'count' => 42 }
      result = renderer.render_default(data)
      expect(result).to include('**status:** ok')
      expect(result).to include('**count:** 42')
    end

    it 'renders empty Array as _(empty)_' do
      expect(renderer.render_default([])).to eq('_(empty)_')
    end

    it 'renders integer scalar as string' do
      expect(renderer.render_default(42)).to eq('42')
    end

    it 'renders string scalar as-is' do
      expect(renderer.render_default('hello')).to eq('hello')
    end

    it 'renders simple Array as bullet list' do
      result = renderer.render_default(%w[one two three])
      expect(result).to include('- one')
      expect(result).to include('- two')
      expect(result).to include('- three')
    end

    it 'renders Hash with nested Hash values indented' do
      data = { 'config' => { 'key' => 'val', 'other' => 'x' } }
      result = renderer.render_default(data)
      expect(result).to include('**config:**')
      expect(result).to include('  - key: val')
      expect(result).to include('  - other: x')
    end

    it 'renders Hash with Array values as item count' do
      data = { 'items' => [1, 2, 3] }
      result = renderer.render_default(data)
      expect(result).to include('**items:** 3 items')
    end
  end

  describe '#render (via dispatch)' do
    it 'falls back to render_default for unknown tool names' do
      result = renderer.render(:unknown_console_tool, { 'key' => 'value' })
      expect(result).to include('**key:** value')
    end
  end
end

RSpec.describe CodebaseIndex::Console::JsonConsoleRenderer do
  let(:renderer) { described_class.new }

  describe '#render_default' do
    it 'returns pretty-printed JSON for a Hash' do
      data = { 'key' => 'value', 'count' => 42 }
      result = renderer.render_default(data)
      expect(JSON.parse(result)).to eq(data)
    end

    it 'returns pretty-printed JSON for an Array of Hashes' do
      data = [{ 'id' => 1 }, { 'id' => 2 }]
      result = renderer.render_default(data)
      expect(JSON.parse(result)).to eq(data)
    end
  end
end
