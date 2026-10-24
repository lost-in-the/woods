# frozen_string_literal: true

require 'woods/impact/value'

RSpec.describe Woods::Impact::Value do
  describe '.same?' do
    pairs = {
      'equal scalars' => %w[a a],
      'different strings' => %w[a b],
      'an integer and its float' => [1, 1.0],
      'equal floats' => [1.5, 1.5],
      'nil and false' => [nil, false],
      'nil and nil' => [nil, nil],
      'a string and a number' => ['1', 1],
      'hashes in another key order' => [{ 'a' => 1, 'b' => [1, 2] }, { 'b' => [1, 2], 'a' => 1 }],
      'a missing key and a nil value' => [{ 'a' => nil }, {}],
      'another key with the same value' => [{ 'a' => 1 }, { 'b' => 1 }],
      'arrays in another order' => [[1, 2], [2, 1]],
      'a longer array' => [[1, 2], [1, 2, 3]],
      'a hash and an array' => [{}, []],
      'nested differences' => [{ 'm' => [{ 'x' => 1, 'y' => { 'z' => 'q' } }] },
                               { 'm' => [{ 'y' => { 'z' => 'r' }, 'x' => 1 }] }],
      'nested equality' => [{ 'm' => [{ 'x' => 1, 'y' => { 'z' => 'q' } }] },
                            { 'm' => [{ 'y' => { 'z' => 'q' }, 'x' => 1 }] }]
    }

    pairs.each do |name, (left, right)|
      it "agrees with comparing canonical JSON for #{name}" do
        expected = described_class.json(left) == described_class.json(right)
        expect([described_class.same?(left, right), described_class.same?(right, left)]).to eq([expected, expected])
      end
    end

    it 'treats negative and positive zero as the same, the one departure from canonical JSON' do
      expect(described_class.same?({ 'x' => [-0.0] }, { 'x' => [0.0] })).to be(true)
    end
  end
end
