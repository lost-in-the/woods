# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/console_response_renderer'

RSpec.describe Woods::Console::ConsoleResponseRenderer do
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

    it 'renders Hash with a scalar Array value as a bullet list' do
      data = { 'items' => %w[one two three] }
      result = renderer.render_default(data)
      expect(result).to include('**items:**')
      expect(result).to include('- one')
      expect(result).to include('- two')
      expect(result).to include('- three')
    end

    it 'renders Hash with an Array<Hash> value as a Markdown table' do
      data = { 'records' => [{ 'id' => 1, 'name' => 'Alice' }, { 'id' => 2, 'name' => 'Bob' }] }
      result = renderer.render_default(data)
      expect(result).to include('**records:**')
      expect(result).to include('| id | name |')
      expect(result).to include('| --- | --- |')
      expect(result).to include('| 1 | Alice |')
      expect(result).to include('| 2 | Bob |')
    end

    it 'renders positional rows as a table using sibling `columns` as headers (sql / query)' do
      data = {
        'columns' => %w[id subdomain crypted_password],
        'rows' => [[1, 'test', '[REDACTED]'], [2, 'other', '[REDACTED]']],
        'count' => 2
      }
      result = renderer.render_default(data)
      expect(result).to include('**rows:**')
      expect(result).to include('| id | subdomain | crypted_password |')
      expect(result).to include('| 1 | test | [REDACTED] |')
      expect(result).to include('| 2 | other | [REDACTED] |')
      expect(result).to include('**count:** 2')
    end

    it 'renders positional multi-column values as a table (pluck multi-column)' do
      data = {
        'columns' => %w[id subdomain],
        'values' => [[1, 'test'], [2, 'other']]
      }
      result = renderer.render_default(data)
      expect(result).to include('| id | subdomain |')
      expect(result).to include('| 1 | test |')
      expect(result).to include('| 2 | other |')
    end

    it 'renders a flat scalar values array against a single-column header (pluck single-column)' do
      data = {
        'columns' => %w[subdomain],
        'values' => %w[alpha beta gamma]
      }
      result = renderer.render_default(data)
      expect(result).to include('| subdomain |')
      expect(result).to include('| alpha |')
      expect(result).to include('| beta |')
      expect(result).to include('| gamma |')
    end

    it 'renders an empty `rows` array as _(empty)_ with the columns key still labeled' do
      data = { 'columns' => %w[id], 'rows' => [], 'count' => 0 }
      result = renderer.render_default(data)
      expect(result).to include('**rows:**')
      expect(result).to include('_(empty)_')
      expect(result).to include('**count:** 0')
    end

    it 'falls back to bullet-list rendering when `values` has no sibling columns' do
      data = { 'values' => [1, 2, 3] }
      result = renderer.render_default(data)
      expect(result).to include('**values:**')
      expect(result).to include('- 1')
      expect(result).to include('- 2')
      expect(result).to include('- 3')
    end
  end

  describe '#render (via dispatch)' do
    it 'falls back to render_default for unknown tool names' do
      result = renderer.render(:unknown_console_tool, { 'key' => 'value' })
      expect(result).to include('**key:** value')
    end
  end
end

RSpec.describe Woods::Console::JsonConsoleRenderer do
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
