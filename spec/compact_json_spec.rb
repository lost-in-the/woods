# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'pathname'
require 'bigdecimal'
require 'woods/compact_json'

RSpec.describe Woods::CompactJson do
  let(:custom) do
    Class.new do
      def to_json(*args)
        { 'custom' => true }.to_json(*args)
      end
    end
  end

  {
    'symbol values and keys' => { type: :model, 'edges' => [{ via: :belongs_to, target: 'User' }],
                                  "odd key\n": :'q"' },
    'keys that are not strings' => { nil => 1, 3 => :x, 1.5 => 'y', %i[a b] => 2 },
    'times and dates' => [Time.utc(2026, 1, 2, 3, 4, 5), Date.new(2026, 1, 2)],
    'objects with no JSON form' => [Pathname.new('/a/b'), Set[1, 2], Rational(1, 3), BigDecimal('1.5'), 1..3],
    'numbers' => [1.0, 1e20, 0.1, -0.0, 12_345_678_901_234_567_890, -7],
    'text' => ["café   </script> \u0001 \\ \"", '€', ''],
    'empty and literal values' => [{}, [], nil, true, false],
    'deep nesting' => { a: { b: [{ c: { d: [:e, [[:f]]] } }] } }
  }.each do |name, value|
    it "writes #{name} as JSON.generate does" do
      expect(described_class.generate(value)).to eq(JSON.generate(value))
    end
  end

  it 'writes an object through its own to_json, and a String subclass as a string' do
    value = [custom.new, Class.new(String).new('sub'), Struct.new(:a).new(1)]

    expect(described_class.generate(value)).to eq(JSON.generate(value))
  end

  it 'refuses what JSON.generate refuses, with the same error' do
    [Float::NAN, Float::INFINITY, "\xFF".dup.force_encoding('UTF-8')].each do |bad|
      expect { described_class.generate([bad]) }.to raise_error(JSON::GeneratorError)
      expect { JSON.generate([bad]) }.to raise_error(JSON::GeneratorError)
    end
  end

  it 'round-trips an extracted unit' do
    unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
    unit.metadata = { associations: [{ name: :posts, macro: :has_many }], git: { change_frequency: :hot } }
    unit.dependencies = [{ type: :model, target: 'Post', via: :has_many }]

    expect(described_class.generate(unit.to_h)).to eq(JSON.generate(unit.to_h))
  end

  it 'falls back to JSON.generate when the coder cannot write the value' do
    coder = described_class.const_get(:CODER)
    allow(coder).to receive(:dump).and_raise(JSON::GeneratorError, 'unsupported')

    expect(described_class.generate({ a: :b })).to eq('{"a":"b"}')
  end
end
