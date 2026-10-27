# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/test_examples'

RSpec.describe Woods::Extractors::TestExamples do
  def table(source, framework: :rspec)
    described_class.call(source, framework: framework)
  end

  def summary(entries, *keys)
    entries.map { |entry| entry.values_at(*keys) }
  end

  describe 'an RSpec file' do
    let(:source) do
      <<~RUBY
        RSpec.describe User, type: :model do
          describe '#name' do
            it 'returns the name' do
              expect(1).to eq(1)
            end

            context 'when blank' do
              it('is nil') { expect(nil).to be_nil }
            end
          end

          specify { expect(1).to eq(1) }
        end
      RUBY
    end

    it 'lists groups and examples in source order with their 1-based extents' do
      expect(summary(table(source), 'kind', 'name', 'line', 'end_line')).to eq(
        [['group', 'User', 1, 13], ['group', '#name', 2, 10], ['example', 'returns the name', 3, 5],
         ['group', 'when blank', 7, 9], ['example', 'is nil', 8, 8], ['example', nil, 12, 12]]
      )
    end

    it 'records the enclosing chain and the full label RSpec builds from it' do
      entries = table(source)

      expect(summary(entries, 'chain', 'label')).to eq(
        [[[], 'User'], [['User'], 'User#name'], [['User', '#name'], 'User#name returns the name'],
         [['User', '#name'], 'User#name when blank'], [['User', '#name', 'when blank'], 'User#name when blank is nil'],
         [['User'], nil]]
      )
    end

    it 'keeps a #name part separate from a string parent, as RSpec does' do
      entries = table("describe 'Account' do\n  describe '#name' do\n    it('x') {}\n  end\nend\n")

      expect(entries.last['label']).to eq('Account #name x')
    end

    it 'marks a label that is not written as dynamic instead of inventing one' do
      entries = table(source)

      expect(entries.last).to include('name' => nil, 'dynamic' => true)
      expect(entries.first).not_to have_key('dynamic')
    end
  end

  describe 'dynamic and generated labels' do
    it 'does not name an interpolated, variable or call description' do
      source = <<~RUBY
        describe Widget do
          it "handles \#{kind}" do; end
          it name do; end
          it build_name do; end
          it 'a' + 'b' do; end
          it 'plain' do; end
        end
      RUBY

      entries = table(source).drop(1)
      expect(summary(entries, 'name',
                     'dynamic')).to eq([[nil, true], [nil, true], [nil, true], [nil, true], ['plain', nil]])
    end

    it 'joins adjacent string literals' do
      expect(table("it 'a' 'b' do; end\n").first['name']).to eq('ab')
    end

    it 'marks a group with an unknown label dynamic for every example under it' do
      source = "describe described do\n  it 'works' do; end\nend\n"

      entries = table(source)
      expect(entries.last).to include('name' => 'works', 'dynamic' => true, 'chain' => [nil])
      expect(entries.last).not_to have_key('label')
    end

    it 'marks a static example made by an iteration block as generated' do
      source = <<~RUBY
        describe Widget do
          %w[a b].each do |kind|
            it 'works' do; end
            it "works for \#{kind}" do; end
          end
        end
      RUBY

      entries = table(source).drop(1)
      expect(summary(entries, 'name', 'generated', 'dynamic')).to eq([['works', true, nil], [nil, true, true]])
    end

    it 'ignores a metadata symbol after the first argument when building a label' do
      entries = table("describe Widget, :slow, 'extra' do\n  it('x') {}\nend\n")

      expect(entries.first['label']).to eq('Widget extra')
    end
  end

  describe 'markers' do
    it 'reads focus, skip and pending from prefixes, metadata symbols and keyword options' do
      source = <<~RUBY
        describe Widget do
          fit 'a' do; end
          xit 'b' do; end
          it 'c', :focus do; end
          it 'd', skip: 'reason' do; end
          it 'e', pending: true do; end
          it 'f', skip: false do; end
          it 'g'
          skip 'h' do; end
          pending 'i' do; end
          xspecify('j') {}
        end
      RUBY

      entries = table(source).drop(1)
      expect(summary(entries, 'name', 'focus', 'skip', 'pending')).to eq(
        [['a', true, nil, nil], ['b', nil, true, nil], ['c', true, nil, nil], ['d', nil, true, nil],
         ['e', nil, nil, true], ['f', nil, nil, nil], ['g', nil, nil, true], ['h', nil, true, nil],
         ['i', nil, nil, true], ['j', nil, true, nil]]
      )
    end

    it 'passes a group marker down to the examples inside it' do
      source = "xdescribe Widget do\n  it('a') {}\n  context('b', :focus) do\n    it('c') {}\n  end\nend\n"

      entries = table(source)
      expect(summary(entries, 'name', 'skip', 'focus')).to eq(
        [['Widget', true, nil], ['a', true, nil], ['b', true, true], ['c', true, true]]
      )
    end

    it 'does not treat a call without a block or argument, or a skip inside a hook, as a definition' do
      source = "describe Widget do\n  before { skip 'later' }\n  let(:it) { 1 }\n  it\nend\n"

      expect(summary(table(source), 'kind', 'name')).to eq([%w[group Widget]])
    end
  end

  describe 'shared groups' do
    let(:source) do
      <<~RUBY
        RSpec.shared_examples 'a lookup' do
          it 'finds it' do; end
        end

        shared_context :logged_in do
        end

        describe Widget do
          it_behaves_like 'a lookup'
          include_examples 'a lookup'
          include_context :logged_in
          it_behaves_like kind
        end
      RUBY
    end

    it 'lists the shared group with its examples and each inclusion by its static name' do
      entries = table(source)

      expect(summary(entries, 'kind', 'name', 'shared', 'via')).to eq(
        [['shared_group', 'a lookup', true, nil], ['example', 'finds it', true, nil],
         ['shared_group', 'logged_in', true, nil], ['group', 'Widget', nil, nil],
         ['include', 'a lookup', nil, 'it_behaves_like'], ['include', 'a lookup', nil, 'include_examples'],
         ['include', 'logged_in', nil, 'include_context'], ['include', nil, nil, 'it_behaves_like']]
      )
    end

    it 'gives a shared example no label, because it is named by whoever includes it' do
      expect(table(source)[1]).not_to have_key('label')
      expect(table(source)[1]).to include('chain' => ['a lookup'])
    end

    it 'marks an inclusion with an unknown name dynamic' do
      expect(table(source).last).to include('dynamic' => true)
    end
  end

  describe 'a Minitest file' do
    let(:source) do
      <<~RUBY
        class WidgetTest < ActiveSupport::TestCase
          test "renders the name" do
            assert true
          end

          test "renders \#{kind}" do
            assert true
          end

          def test_total
            assert true
          end

          def helper
          end
        end

        class HelperOnly
        end
      RUBY
    end

    it 'reads test blocks and test_ methods under their class, and skips a class with none' do
      entries = table(source, framework: :minitest)

      expect(summary(entries, 'kind', 'name', 'line', 'end_line')).to eq(
        [['group', 'WidgetTest', 1, 16], ['example', 'renders the name', 2, 4], ['example', nil, 6, 8],
         ['example', 'test_total', 10, 12]]
      )
      expect(entries[1]).to include('chain' => ['WidgetTest'], 'label' => 'WidgetTest renders the name')
      expect(entries[2]).to include('dynamic' => true)
    end

    it 'reads the spec DSL in a Minitest file too' do
      entries = table("describe Widget do\n  it 'works' do; end\nend\n", framework: :minitest)

      expect(summary(entries, 'kind', 'name')).to eq([%w[group Widget], %w[example works]])
    end

    it 'does not read test_ methods or classes in an RSpec file' do
      expect(table(source, framework: :rspec)).to eq([])
    end
  end

  describe 'source it cannot read' do
    it 'returns no table for source that does not parse, and an empty one for a file with no examples' do
      expect(described_class.call("describe Widget do\n  it 'x' do\n")).to be_nil
      expect(described_class.call(nil)).to be_nil
      expect(described_class.call("puts 1\n")).to eq([])
    end
  end

  describe '.record' do
    def unit(type, source, framework: :rspec)
      Woods::ExtractedUnit.new(type: type, identifier: 'spec/widget_spec.rb',
                               file_path: 'spec/widget_spec.rb').tap do |u|
        u.source_code = source
        u.metadata = { test_framework: framework }
      end
    end

    it 'writes metadata.examples on a test mapping unit' do
      record = unit(:test_mapping, "describe Widget do\n  it('x') {}\nend\n")
      described_class.record(record)

      expect(record.metadata[:examples].map { |entry| entry['name'] }).to eq(%w[Widget x])
    end

    it 'drops a stale table when the source no longer parses and leaves other unit types alone' do
      record = unit(:test_mapping, "describe Widget do\n")
      record.metadata[:examples] = [{ 'stale' => true }]
      described_class.record(record)
      expect(record.metadata).not_to have_key(:examples)

      model = unit(:model, "describe Widget do\n  it('x') {}\nend\n")
      described_class.record(model)
      expect(model.metadata).not_to have_key(:examples)
    end
  end
end
