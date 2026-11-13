# frozen_string_literal: true

require 'spec_helper'
require 'woods/edge_evidence'
require 'woods/source_references/registry'

# The rule: an edge's evidence is read from a catalog keyed by the edge's
# source unit type and its `via`. A pair two mechanisms can produce takes the
# weaker class, and a pair the catalog does not list is `unknown`, never a
# default class.
RSpec.describe Woods::EdgeEvidence do
  describe '.for' do
    it 'answers reflected for what Rails itself reports' do
      expect(described_class.for('model', 'belongs_to')).to eq('reflected')
      expect(described_class.for('route', 'route_dispatch')).to eq('reflected')
      expect(described_class.for('database_table', 'foreign_key')).to eq('reflected')
      expect(described_class.for('controller', 'inheritance')).to eq('reflected')
    end

    it 'answers verified for source resolved against the running application' do
      expect(described_class.for('controller', 'redirect_to')).to eq('verified')
      expect(described_class.for('view_template', 'link_to')).to eq('verified')
      expect(described_class.for('component', 'render')).to eq('verified')
      expect(described_class.for('migration', 'migrates')).to eq('verified')
    end

    it 'answers static for a source-text match nothing checked' do
      expect(described_class.for('model', 'job_enqueue')).to eq('static')
      expect(described_class.for('pundit_policy', 'authorization')).to eq('static')
      expect(described_class.for('test_mapping', 'test_coverage')).to eq('static')
    end

    it 'accepts symbols as the graph holds them' do
      expect(described_class.for(:model, :has_many)).to eq('reflected')
    end

    it 'classifies by the source type: one via differs between source types' do
      expect(described_class.for('model', 'include')).to eq('verified')
      expect(described_class.for('concern', 'include')).to eq('static')
      expect(described_class.for('service', 'include')).to eq('verified')
      expect(described_class.for('controller', 'inheritance')).to eq('reflected')
      expect(described_class.for('lib', 'inheritance')).to eq('verified')
    end

    it 'answers unknown for an unlisted pair, an unlabelled edge and an unknown type' do
      expect(described_class.for('model', 'teleports_to')).to eq('unknown')
      expect(described_class.for('model', nil)).to eq('unknown')
      expect(described_class.for('model', '')).to eq('unknown')
      expect(described_class.for('hologram', 'belongs_to')).to eq('unknown')
      expect(described_class.for(nil, 'belongs_to')).to eq('unknown')
    end
  end

  describe '.mixed?' do
    it 'is true for a pair two mechanisms produce, which takes the weaker class' do
      expect(described_class.mixed?('controller', 'code_reference')).to be(true)
      expect(described_class.for('controller', 'code_reference')).to eq('static')
      expect(described_class.mixed?('view_template', 'render')).to be(true)
      expect(described_class.mixed?(:lib, :inheritance)).to be(true)
    end

    it 'is false for a pair one mechanism produces, and for an unknown pair' do
      expect(described_class.mixed?('model', 'belongs_to')).to be(false)
      expect(described_class.mixed?('rake_task', 'code_reference')).to be(false)
      expect(described_class.mixed?('model', 'teleports_to')).to be(false)
    end
  end

  describe '.weakest and .strongest' do
    it 'orders static below verified below reflected' do
      expect(described_class.weakest(%w[reflected static verified])).to eq('static')
      expect(described_class.weakest(%w[reflected verified])).to eq('verified')
      expect(described_class.strongest(%w[static reflected verified])).to eq('reflected')
      expect(described_class.strongest(%w[static verified])).to eq('verified')
    end

    it 'lets one unknown make the weakest unknown' do
      expect(described_class.weakest(%w[reflected unknown])).to eq('unknown')
    end

    it 'ignores an unknown beside a known class when taking the strongest' do
      expect(described_class.strongest(%w[unknown static])).to eq('static')
      expect(described_class.strongest(%w[unknown])).to eq('unknown')
    end

    it 'answers nil for nothing to compare' do
      expect(described_class.weakest([])).to be_nil
      expect(described_class.strongest([])).to be_nil
    end
  end

  describe '.edge' do
    it 'takes the strongest via between two units' do
      expect(described_class.edge('model', %w[code_reference belongs_to])).to eq(evidence: 'reflected', mixed: false)
    end

    it 'is mixed only when every via of the strongest class is mixed' do
      expect(described_class.edge('controller', %w[code_reference])).to eq(evidence: 'static', mixed: true)
      expect(described_class.edge('controller', %w[code_reference job_enqueue]))
        .to eq(evidence: 'static', mixed: false)
    end

    it 'is unknown for an unlabelled edge' do
      expect(described_class.edge('model', [])).to eq(evidence: 'unknown', mixed: false)
      expect(described_class.edge('model', [nil])).to eq(evidence: 'unknown', mixed: false)
    end
  end

  describe '.label' do
    it 'says "at least" for a mixed pair' do
      expect(described_class.label('static', true)).to eq('at least static')
      expect(described_class.label('reflected', false)).to eq('reflected')
      expect(described_class.label('unknown', false)).to eq('unknown')
    end
  end

  describe 'the catalog' do
    let(:pairs) { described_class::CATALOG.flat_map { |type, vias| vias.keys.map { |via| [type, via] } } }

    it 'is frozen, keyed by strings, and holds only the three known classes' do
      expect(described_class::CATALOG).to be_frozen
      described_class::CATALOG.each do |type, vias|
        expect(type).to be_a(String)
        expect(vias).to be_frozen
        expect(vias.keys).to all(be_a(String))
        expect(vias.values - described_class::ORDER).to eq([]), "#{type} holds a class outside ORDER"
      end
      expect(described_class::ORDER).to eq(%w[static verified reflected])
      expect(described_class::CLASSES).to eq(%w[reflected verified static unknown])
    end

    it 'records every mixed pair in the catalog, with a reason' do
      expect(described_class::MIXED).to be_frozen
      expect(described_class::MIXED.keys - pairs).to eq([])
      expect(described_class::MIXED.values).to all(be_a(String).and(match(/\S/)))
    end

    it 'never classifies a mixed pair as reflected: one of its mechanisms is weaker' do
      classes = described_class::MIXED.keys.map { |type, via| described_class.for(type, via) }
      expect(classes).not_to include('reflected')
    end

    it 'gives every type the reference pass writes for its three labels' do
      registry = Woods::SourceReferences::Registry::TYPES.map(&:to_s)
      expect(described_class::REFERENCE_PASS_TYPES).to match_array(registry)
      registry.each do |type|
        %w[code_reference include extend].each do |via|
          expect(%w[static verified]).to include(described_class.for(type, via)), "#{type} #{via}"
        end
      end
    end

    it 'never calls a label the reference pass shares with an extractor scan anything but mixed' do
      shared = described_class::REFERENCE_PASS_TYPES.product(%w[code_reference include extend]).select do |type, via|
        described_class.for(type, via) == 'static'
      end
      expect(shared - described_class::MIXED.keys).to eq([])
    end
  end

  describe 'the documented catalog' do
    let(:doc) { File.read(File.expand_path('../docs/MCP_SERVERS.md', __dir__), encoding: 'UTF-8') }

    it 'matches the catalog row for row' do
      documented = doc[/<!-- edge-evidence-catalog:start -->\n(.*?)<!-- edge-evidence-catalog:end -->/m, 1]
      expect(documented).not_to be_nil, 'docs/MCP_SERVERS.md has no edge-evidence-catalog block'
      expect(documented).to eq("#{described_class.markdown_table}\n"),
                            'Regenerate the table: ruby -Ilib -e ' \
                            '"require \'woods/edge_evidence\'; puts Woods::EdgeEvidence.markdown_table"'
    end
  end
end
