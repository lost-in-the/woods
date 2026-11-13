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
    block = "# ┌─┐\n# │ Included from: Tagging                                               │\n# └─┘\n  " \
            "# module Tagging\n  #   def label; end\n  # end\n# ─────── End Tagging ───────\n"
    units = { 'Post' => unit('Post', 'Record', block, type: 'model'),
              'Record' => unit('Record', 'Object', "  def label; end\n", type: 'poro') }

    resolution = resolve(units, 'Post#label')
    expect(resolution.chosen.concern).to eq('Tagging')
    expect(resolution.caveats).to eq(['The superclass chain of Post was read only up to Post: its parent Record is ' \
                                      'published as a poro unit, which does not inline its concerns, so a ' \
                                      'definition in a superclass Woods did not read could come before this ' \
                                      'inlined concern.'])
  end

  it 'reads a parent from the :inheritance edge before parent_class' do
    child = unit('Child', 'Ignored').merge('dependencies' => [{ 'type' => 'service', 'target' => 'Parent',
                                                                'via' => 'inheritance' }])
    units = { 'Child' => child, 'Parent' => unit('Parent', 'Object', "  def call; end\n") }

    expect(resolve(units, 'Child#call').chosen.unit['identifier']).to eq('Parent')
  end
end
