# frozen_string_literal: true

require 'spec_helper'
require 'woods/impact/line_diff'

RSpec.describe Woods::Impact::LineDiff do
  def ranges(before, after, max_hunks: 10)
    described_class.new(before, after).ranges(max_hunks: max_hunks)
  end

  it 'reports changed ranges in git -U0 coordinates with added and removed counts' do
    expect(ranges("one\ntwo\nthree\nfour\n", "one\n2\nthree\nfour\nfive\nsix\n")).to eq(
      'hunks' => [{ 'before' => [2, 1], 'after' => [2, 1] }, { 'before' => [4, 0], 'after' => [5, 2] }],
      'added_lines' => 3, 'removed_lines' => 1, 'coverage' => 'complete'
    )
  end

  it 'starts an empty side at the line before the change' do
    expect(ranges("a\nb\n", "x\na\nb\n")['hunks']).to eq([{ 'before' => [0, 0], 'after' => [1, 1] }])
    expect(ranges("a\nb\nc\n", "a\nc\n")['hunks']).to eq([{ 'before' => [2, 1], 'after' => [1, 0] }])
    expect(ranges("a\n", "a\n")).to include('hunks' => [], 'added_lines' => 0, 'coverage' => 'complete')
  end

  it 'keeps the first hunks within a bound and says it truncated' do
    result = ranges("a\nb\nc\nd\ne\n", "A\nb\nC\nd\nE\n", max_hunks: 2)
    expect(result).to include('coverage' => 'truncated', 'added_lines' => 3, 'removed_lines' => 3)
    expect(result['hunks'].size).to eq(2)
  end

  it 'claims nothing past its bounds' do
    before = (1..3000).to_a.join("\n")
    after = (1..3000).map { |i| (i * 7).to_s }.join("\n")
    expect(ranges(before, after)).to eq('hunks' => [], 'added_lines' => nil, 'removed_lines' => nil,
                                        'coverage' => 'too_large')
  end

  it 'gives unified hunks with context, line numbers on both sides and the text' do
    unified = described_class.new("one\ntwo\nthree\nfour\n", "one\n2\nthree\nfour\nfive\n").unified(max_lines: 50,
                                                                                                    context: 1)
    expect(unified['hunks'].map { |hunk| [hunk['before'], hunk['after']] }).to eq([[[1, 4], [1, 5]]])
    expect(unified['hunks'].first['lines'].map { |line| line.values_at('op', 'before', 'after', 'text') }).to eq(
      [[' ', 1, 1, 'one'], ['-', 2, nil, 'two'], ['+', nil, 2, '2'], [' ', 3, 3, 'three'], [' ', 4, 4, 'four'],
       ['+', nil, 5, 'five']]
    )
  end

  it 'bounds the unified lines and marks the cut' do
    unified = described_class.new("a\nb\nc\n", "x\ny\nz\n").unified(max_lines: 2, context: 0)
    expect(unified['coverage']).to eq('truncated')
    expect(unified['hunks'].sum { |hunk| hunk['lines'].size }).to eq(2)
  end
end
