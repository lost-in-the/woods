# frozen_string_literal: true

require 'spec_helper'
require 'woods/impact/range_diff'

RSpec.describe Woods::Impact::RangeDiff, 'column changes (#821)' do
  def table(columns, **metadata)
    { 'identifier' => 'table:posts', 'type' => 'database_table', 'source_code' => '',
      'metadata' => { 'columns' => columns }.merge(metadata.transform_keys(&:to_s)), 'dependencies' => [] }
  end

  def column(name, type = 'string', null: true)
    { 'name' => name, 'type' => type, 'null' => null }
  end

  let(:key) { ['table:posts', 'database_table'] }

  def record(before, after)
    described_class.new({ key => before }.compact, { key => after }.compact).changes.first
  end

  it 'names the columns added, removed and modified by name, sorted' do
    before = table([column('id', 'integer'), column('title'), column('state'), column('legacy')])
    after = table([column('id', 'integer'), column('title'), column('state', null: false), column('body', 'text'),
                   column('author_id', 'integer')])

    expect(record(before, after)['column_changes'])
      .to eq('added' => %w[author_id body], 'removed' => %w[legacy], 'modified' => %w[state])
  end

  it 'adds nothing when the columns did not move, for added or removed units, or without named columns' do
    same = [column('id', 'integer')]
    expect(record(table(same, column_count: 1), table(same, column_count: 2))).not_to have_key('column_changes')
    expect(record(nil, table(same))).not_to have_key('column_changes')
    expect(record(table(same), nil)).not_to have_key('column_changes')
    expect(record(table(['id']), table(%w[id title]))).not_to have_key('column_changes')
  end
end
