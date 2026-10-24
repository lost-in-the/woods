# frozen_string_literal: true

require 'spec_helper'
require 'woods/published_index'
require 'tmpdir'
require 'json'

RSpec.describe Woods::PublishedIndex, '#units_with (#837)' do
  def open_with(graph, &block)
    Dir.mktmpdir('woods-node-facts') do |dir|
      File.write(File.join(dir, 'manifest.json'), '{}')
      File.write(File.join(dir, 'dependency_graph.json'), JSON.generate(graph))
      described_class.open(dir, &block)
    end
  end

  let(:graph) do
    { 'nodes' => { 'WidgetsController' => { 'type' => 'controller', 'unresolved_render_count' => 2,
                                            'fact_actions' => %w[index show] },
                   'Gadget' => { 'type' => 'model' },
                   'shared' => { 'type' => 'view_component', 'unresolved_render_count' => 1 } },
      'variants' => [{ 'identifier' => 'shared', 'type' => 'component', 'unresolved_render_count' => 3,
                       'edges' => [] }],
      'edges' => {}, 'node_facts' => %w[fact_actions unresolved_render_count] }
  end

  it 'names the typed units that carry unresolved renders, variants included, without opening a unit' do
    open_with(graph) do |index|
      expect(index).not_to receive(:unit)
      expect(index.units_with(:unresolved_renders)).to eq(
        [{ 'identifier' => 'WidgetsController', 'type' => 'controller', 'count' => 2 },
         { 'identifier' => 'shared', 'type' => 'component', 'count' => 3 },
         { 'identifier' => 'shared', 'type' => 'view_component', 'count' => 1 }]
      )
    end
  end

  it 'names the actions each unit publishes facts for' do
    open_with(graph) do |index|
      expect(index.units_with(:action_facts))
        .to eq([{ 'identifier' => 'WidgetsController', 'type' => 'controller', 'actions' => %w[index show] }])
    end
  end

  it 'answers nil for a generation whose writer did not summarise, so a reader falls back' do
    open_with(graph.except('node_facts')) do |index|
      expect(index.units_with(:unresolved_renders)).to be_nil
    end
    open_with(graph) do |index|
      expect { index.units_with(:columns) }.to raise_error(ArgumentError, /columns/)
    end
  end
end
