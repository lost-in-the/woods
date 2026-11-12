# frozen_string_literal: true

require 'spec_helper'
require 'woods/parse_cache'
require 'woods/extractors/comment_blanking'

RSpec.describe Woods::ParseCache do
  let(:source) { "class Ledger\n  def call = Shipment.new\nend\n" }

  it 'is a plain parse outside a run' do
    expect(described_class.active).to be_nil
    allow(Prism).to receive(:parse).and_call_original
    described_class.parse(source)
    described_class.parse(source)
    expect(Prism).to have_received(:parse).twice
  end

  it 'parses each distinct source once inside a run, including an equal copy' do
    allow(Prism).to receive(:parse).and_call_original
    described_class.with do
      first = described_class.parse(source)
      expect(described_class.parse(source.dup)).to equal(first)
      described_class.parse("module Widget; end\n")
      expect(described_class.active.parses).to eq(2)
      expect(described_class.active.hits).to eq(1)
    end
    expect(Prism).to have_received(:parse).twice
    expect(described_class.active).to be_nil
  end

  it 'keeps the outer run\'s cache across a nested with' do
    described_class.with do
      outer = described_class.active
      described_class.with { expect(described_class.active).to equal(outer) }
      expect(described_class.active).to equal(outer)
    end
  end

  it 'clears the cache when the run raises' do
    expect { described_class.with { raise 'boom' } }.to raise_error('boom')
    expect(described_class.active).to be_nil
  end

  it 'memoizes other derivations of a source by family' do
    described_class.with do
      calls = 0
      ast = described_class.derive(:ast, source) do
        calls += 1
        :tree
      end
      expect(described_class.derive(:ast, source) { raise 'recomputed' }).to equal(ast)
      expect(described_class.derive(:other, source) { :other }).to eq(:other)
      expect(calls).to eq(1)
    end
  end

  it 'evicts the least recently used source past the byte budget' do
    big = "class Big\n#{'  def m; end' * 200}\nend\n"
    small = "class Small; end\n"
    described_class.with(budget: big.bytesize + small.bytesize + 1) do
      described_class.parse(big)
      described_class.parse(small)
      described_class.parse(big) # big is now most recent
      described_class.parse("class Third; end\n") # pushes the budget over: small goes
      expect(described_class.active.hits).to eq(1)
      described_class.parse(small)
      expect(described_class.active.parses).to eq(4)
    end
  end

  it 'never caches a source larger than the whole budget' do
    described_class.with(budget: 8) do
      described_class.parse(source)
      described_class.parse(source)
      expect(described_class.active.parses).to eq(2)
    end
  end

  it 'is disabled by a zero budget' do
    described_class.with(budget: 0) { expect(described_class.active).to be_nil }
  end

  it 'returns one analysis per thread when threads share the run' do
    sources = Array.new(16) { |i| "class Model#{i}\n  def call = Dep#{i}.new\nend\n" }
    described_class.with do
      names = ->(src) { described_class.parse(src).value.statements.body.first.constant_path.name }
      results = Array.new(4) { Thread.new { sources.map(&names) } }.map(&:value)
      expect(results.uniq.size).to eq(1)
      expect(results.first).to eq(Array.new(16) { |i| :"Model#{i}" })
    end
  end
end

RSpec.describe Woods::Extractors::CommentBlanking, 'within a parse cache' do
  let(:source) { "class Order\n  # ships a Widget\n  def ship; end\nend\n" }

  it 'blanks a source once for every scanner that reads it in a run' do
    Woods::ParseCache.with do
      first = described_class.ruby(source)

      expect(first).to eq("class Order\n                  \n  def ship; end\nend\n")
      expect(first).to be_frozen
      expect(described_class.ruby(source.dup)).to equal(first)
      expect(described_class.blank(source.dup, 'app/models/order.rb')).to equal(first)
    end
  end

  it 'keeps one result per encoding of the same bytes' do
    Woods::ParseCache.with do
      utf8 = described_class.ruby(source)
      binary = described_class.ruby(source.b)

      expect(binary.encoding).to eq(Encoding::BINARY)
      expect(utf8.encoding).to eq(Encoding::UTF_8)
    end
  end

  it 'still blanks without a cache' do
    expect(described_class.ruby(source)).not_to include('Widget')
  end
end
