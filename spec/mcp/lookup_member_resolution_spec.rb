# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/lookup_member'

# The superclass walk behind a member answer: bounded, cycle-safe, and
# stopped where the published index cannot place an inlined concern.
RSpec.describe Woods::MCP::LookupMember::Resolution do
  def unit(identifier, parent, body = '', type: 'service')
    { 'identifier' => identifier, 'type' => type, 'file_path' => "app/#{identifier.downcase}.rb",
      'source_code' => "class #{identifier} < #{parent}\n#{body}end\n", 'metadata' => { 'parent_class' => parent } }
  end

  # An inlined Tagging concern block, as the extractors frame it.
  def tagging_block
    ['# ┌─┐', "# │ Included from: Tagging#{' ' * 47}│", '# └─┘', '  # module Tagging', '  #   def label; end',
     '  # end', '# ─────── End Tagging ───────'].map { |line| "#{line}\n" }.join
  end

  def resolve(units, identifier)
    reference = Woods::MCP::LookupMember.parse(identifier)
    find = ->(name, _type) { units[name] }
    described_class.new(units.fetch(reference.owner), reference, find_unit: find).call
  end

  it 'ends a cyclic chain without a definition' do
    units = { 'Alpha' => unit('Alpha', 'Beta'), 'Beta' => unit('Beta', 'Alpha') }

    expect(resolve(units, 'Alpha#missing')).to be_nil
  end

  it 'finds a definition across a cyclic chain once' do
    units = { 'Alpha' => unit('Alpha', 'Beta'), 'Beta' => unit('Beta', 'Alpha', "  def call; end\n") }

    resolution = resolve(units, 'Alpha#call')
    expect(resolution.chosen.unit['identifier']).to eq('Beta')
    expect(resolution.chain.map { |found| found['identifier'] }).to eq(%w[Alpha Beta])
  end

  it 'reads at most MAX_DEPTH units of the chain' do
    depth = described_class::MAX_DEPTH
    units = (0..depth).to_h { |index| ["Level#{index}", unit("Level#{index}", "Level#{index + 1}")] }
    units["Level#{depth}"] = unit("Level#{depth}", 'Object', "  def call; end\n")
    units["Level#{depth - 1}"] = unit("Level#{depth - 1}", "Level#{depth}")

    expect(resolve(units, 'Level0#call')).to be_nil
    expect(resolve(units, 'Level1#call').chosen.unit['identifier']).to eq("Level#{depth}")
  end

  it "stops an inlining unit's walk at a parent published as a type that does not inline concerns" do
    block = tagging_block
    units = { 'Post' => unit('Post', 'Record', block, type: 'model'),
              'Record' => unit('Record', 'Object', "  def label; end\n", type: 'poro') }

    resolution = resolve(units, 'Post#label')
    expect(resolution.chosen.concern).to eq('Tagging')
    expect(resolution.caveats).to eq(['No unit Woods read (Post) includes Tagging in its own body, so Post ' \
                                      'includes it through a superclass Woods did not read (its parent Record is ' \
                                      'published as a poro unit, which does not inline its concerns); that ' \
                                      "superclass's own definition of label could come first."])
  end

  it 'needs no caveat when the unit writes the include itself, under an unread parent' do
    block = tagging_block
    units = { 'Post' => unit('Post', 'ApplicationRecord', "  include ::Tagging\n#{block}", type: 'model') }

    expect(resolve(units, 'Post#label').caveats).to eq([])
  end

  it 'keeps the caveat when the written include is dynamic or names another constant' do
    block = tagging_block
    %w[include(tagging_module) include(Other::Tagging)].each do |call|
      units = { 'Post' => unit('Post', 'ApplicationRecord', "  #{call}\n#{block}", type: 'model') }

      expect(resolve(units, 'Post#label').caveats.size).to eq(1), call
    end
  end

  it 'resolves a short name written in the unit namespace to the namespaced concern only' do
    resolve = Woods::MCP::LookupMember::Resolution::Mixins.method(:resolve)

    expect(resolve.call('Tagging', %w[Shop::Post Shop], %w[Shop::Tagging Tagging])).to eq('Shop::Tagging')
    expect(resolve.call('::Tagging', %w[Shop::Post Shop], %w[Shop::Tagging Tagging])).to eq('Tagging')
    expect(resolve.call('Tagging', %w[Shop::Post Shop], %w[Admin::Tagging])).to be_nil
  end

  it 'stops at a parent its typed edge names when only another type is published, naming both types' do
    child = unit('PostsController', 'Ignored', tagging_block, type: 'controller')
            .merge('dependencies' => [{ 'type' => 'controller', 'target' => 'Shared', 'via' => 'inheritance' }])
    units = { 'PostsController' => child, 'Shared' => unit('Shared', 'Object', "  def label; end\n", type: 'model') }

    resolution = resolve(units, 'PostsController#label')
    expect(resolution.chain.map { |found| found['identifier'] }).to eq(%w[PostsController])
    expect(resolution.chosen.concern).to eq('Tagging')
    expect(resolution.caveats.join).to include('its parent Shared is not a published controller unit; the unit ' \
                                               'published as Shared is a model unit')
  end

  it 'reads a parent from the :inheritance edge before parent_class' do
    child = unit('Child', 'Ignored').merge('dependencies' => [{ 'type' => 'service', 'target' => 'Parent',
                                                                'via' => 'inheritance' }])
    units = { 'Child' => child, 'Parent' => unit('Parent', 'Object', "  def call; end\n") }

    expect(resolve(units, 'Child#call').chosen.unit['identifier']).to eq('Parent')
  end

  # A name under an affix: a literal one exactly; an :unknown prefix nothing,
  # or one or more characters then `_`; an :unknown suffix nothing, or `_`
  # then one or more characters.
  describe 'Macros.affixed?' do
    {
      ['glow', 'glow', :unknown, ''] => true,
      ['lamp_glow', 'glow', :unknown, ''] => true,
      ['glow_glow', 'glow', :unknown, ''] => true,
      ['xglow', 'glow', :unknown, ''] => false,
      ['_glow', 'glow', :unknown, ''] => false,
      ['glow_on', 'glow', '', :unknown] => true,
      ['glowon', 'glow', '', :unknown] => false,
      ['glow_', 'glow', '', :unknown] => false,
      ['a_glow_b', 'glow', :unknown, :unknown] => true,
      ['glow', 'glow', :unknown, :unknown] => true,
      ['aglow_b', 'glow', :unknown, :unknown] => false,
      ['a_glowb', 'glow', :unknown, :unknown] => false,
      %w[settings_tone_x tone settings_ _x] => true,
      %w[settings_tone tone settings_ _x] => false,
      ['paint_hue', 'hue', 'paint_', ''] => true,
      ['paint_hue_x', 'hue', 'paint_', ''] => false,
      ['paint_hue', 'hue', 'paint_', :unknown] => true,
      ['x_paint_hue', 'hue', 'paint_', :unknown] => false,
      ['hue_paint', 'hue', :unknown, '_paint'] => true,
      ['xglow_glow', 'glow', :unknown, ''] => true,
      ['aglow_b_glow_c', 'glow', :unknown, :unknown] => true,
      ['a_glowb_glow', 'glow', :unknown, :unknown] => true,
      ['a_b_a_b_c', 'a_b', :unknown, :unknown] => true,
      ['xa_ba_bx', 'a_b', :unknown, :unknown] => false,
      ['lamp_glow', '', :unknown, ''] => false
    }.each do |(name, base, prefix, suffix), expected|
      it "is #{expected} for #{name.inspect} as #{prefix.inspect} + #{base.inspect} + #{suffix.inspect}" do
        expect(described_class::Macros.affixed?(name, base, prefix, suffix)).to be(expected)
      end
    end

    # CPU time of this thread, not wall time, as the method-effects scan is
    # bounded: the work is linear in the name, not in its repetitions squared.
    it 'stays linear on a long name that repeats the base' do
      name = "#{'glow' * 40_000}x"
      clock = Process::CLOCK_THREAD_CPUTIME_ID
      started = Process.clock_gettime(clock)
      affixes = [%i[unknown unknown], [:unknown, ''], ['lamp_', :unknown], ['', '_x']]
      results = affixes.map do |prefix, suffix|
        described_class::Macros.affixed?(name, 'glow', prefix, suffix)
      end
      elapsed = Process.clock_gettime(clock) - started

      expect(results).to eq([false, false, false, false])
      expect(elapsed).to be < 0.1
    end

    it 'stays linear on a long base that overlaps itself all along the name' do
      base = 'a' * 20_000
      name = 'a' * 60_000
      joined = "#{'a_' * 30_000}a"
      clock = Process::CLOCK_THREAD_CPUTIME_ID
      started = Process.clock_gettime(clock)
      results = [described_class::Macros.affixed?(name, base, :unknown, :unknown),
                 described_class::Macros.affixed?("#{name}x", base, :unknown, ''),
                 described_class::Macros.affixed?(joined, 'a_' * 10_000, :unknown, :unknown)]
      elapsed = Process.clock_gettime(clock) - started

      expect(results).to eq([false, false, false])
      expect(elapsed).to be < 0.1
    end
  end

  describe Woods::MCP::LookupMember::Resolution::WrittenName do
    it 'is the identifier when a declaration in the source qualifies to it' do
      source = "class Outer\n  class Inner < Outer\n  end\nend\n"

      expect(described_class.call(source, 'Outer::Inner')).to eq('Outer::Inner')
    end

    it "is the slice's own declaration for a class published as its own lexical range" do
      expect(described_class.call("  class Inner < Outer\n  end\n", 'App::Outer::Inner')).to eq('Inner')
    end

    it 'does not take a top-level class of the same short name when the identifier is declared in full' do
      source = "class Inner\nend\nmodule App\n  class Inner\n  end\nend\n"

      expect(described_class.call(source, 'App::Inner')).to eq('App::Inner')
    end

    it 'is the identifier when the source does not parse' do
      expect(described_class.call("class Inner\n", 'App::Inner')).to eq('App::Inner')
    end
  end
end
