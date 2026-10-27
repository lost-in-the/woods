# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'

RSpec.describe 'Controllers re-extracted for unresolved renders on a Ruby edit' do
  include_context 'isolated Woods runtime'

  around do |example|
    Dir.mktmpdir('woods-render-retarget') do |root|
      @root = Pathname.new(root)
      example.run
    end
  end

  let(:extractor) { Woods::Extractor.new(output_dir: @root.join('index')) }
  let(:graph) { extractor.instance_variable_get(:@dependency_graph) }

  def controller(identifier, unresolved: [])
    Woods::ExtractedUnit.new(type: :controller, identifier: identifier, file_path: "#{@root}/#{identifier}.rb")
                        .tap { |unit| unit.metadata = { unresolved_renders: unresolved } }
  end

  def change(*paths)
    Woods::ChangeSet.new(paths: paths.map { |path| "#{@root}/#{path}" }, root: @root)
  end

  before do
    stub_const('Rails', double('Rails', root: @root, logger: double('Logger').as_null_object, version: '8.0.0'))
    graph.register(controller('OpenController', unresolved: [{ 'name' => 'Missing::Card' }]))
    graph.register(controller('ClosedController'))
  end

  it 'selects only the controllers that still have an unresolved render, on a Ruby edit anywhere' do
    ids = extractor.send(:render_retarget_ids, change('app/services/missing/card.rb'))

    expect(ids).to eq(['OpenController'])
  end

  it 'selects nothing for a change that touches no Ruby file' do
    expect(extractor.send(:render_retarget_ids, change('config/locales/en.yml'))).to eq([])
  end
end
