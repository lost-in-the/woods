# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'

RSpec.describe 'Controllers re-extracted for render target changes on a Ruby edit' do
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
    path = @root.join('app/services/unrelated.rb')
    path.dirname.mkpath
    path.write('class Unrelated; end')
    allow(extractor).to receive(:read_published_unit).and_return({ 'metadata' => {}, 'dependencies' => [] })
    ids = extractor.send(:render_retarget_ids, change('app/services/unrelated.rb'))

    expect(ids).to eq(['OpenController'])
  end

  it 'selects nothing for a change that touches no Ruby file' do
    expect(extractor.send(:render_retarget_ids, change('config/locales/en.yml'))).to eq([])
  end

  describe 'resolved render selection' do
    let(:published) { {} }

    before do
      %w[OpenController ClosedController].each { |id| graph.unregister(id, type: :controller) }
      allow(extractor).to receive(:read_published_unit) { |id, type| published[[type, id]] }
      add_controller('ShelfController', target: 'Card')
      add_controller('OtherController', target: 'Tile')
    end

    def add_controller(id, target: nil)
      unit = controller(id)
      unit.dependencies = target ? [{ target: target, via: :render }] : []
      graph.register(unit)
      published[[:controller, id]] = JSON.parse(JSON.generate(unit.to_h))
    end

    def write_source(path, source, before: nil, identifier: 'LibraryUtility')
      absolute = @root.join(path)
      absolute.dirname.mkpath
      absolute.write(source)
      if before
        unit = Woods::ExtractedUnit.new(type: :lib, identifier: identifier, file_path: absolute.to_s)
        unit.source_code = before
        graph.register(unit)
        published[[:lib, identifier]] = JSON.parse(JSON.generate(unit.to_h))
      end
      change(path)
    end

    it 'does not refresh the controller family wholesale for a readable lib edit' do
      changes = write_source('lib/library_utility.rb', 'class LibraryUtility; def value = 2; end',
                             before: 'class LibraryUtility; def value = 1; end')

      expect(extractor.send(:hybrid_discovery_keys, changes, [])).not_to include(:controllers)
      expect(extractor.send(:render_retarget_ids, changes)).to be_empty
    end

    it 'selects only the controller whose resolved render can be shadowed by a lib constant' do
      changes = write_source('lib/shelf.rb', 'module Shelf; class Card; end; end',
                             before: 'module Shelf; end', identifier: 'Shelf')

      expect(extractor.send(:render_retarget_ids, changes)).to eq(['ShelfController'])
    end

    it 'does not conflate a namespaced Base with an unrelated controller ancestor' do
      stub_const('SelectionFramework', Module.new)
      stub_const('SelectionFramework::Base', Class.new)
      stub_const('ShelfController', Class.new(SelectionFramework::Base))
      changes = write_source('app/services/importers/base.rb', 'class Importers::Base; end')

      expect(extractor.send(:render_retarget_ids, changes)).to be_empty
    end

    it 'selects descendants of the qualified controller ancestor whose includes changed' do
      stub_const('SelectionFramework', Module.new)
      stub_const('SelectionFramework::Base', Class.new)
      stub_const('ShelfController', Class.new(SelectionFramework::Base))
      changes = write_source('lib/selection_framework/base.rb',
                             'class SelectionFramework::Base; include Fancy; end',
                             before: 'class SelectionFramework::Base; end', identifier: 'SelectionFramework::Base')

      expect(extractor.send(:render_retarget_ids, changes)).to eq(['ShelfController'])
    end

    it 'conservatively selects every controller for opaque Ruby changes' do
      changes = write_source('lib/dynamic.rb', 'Object.const_set(:Card, Class.new)')

      expect(extractor.send(:render_retarget_ids, changes)).to contain_exactly('ShelfController', 'OtherController')
    end

    it 'conservatively selects every controller when a lib file has no recorded previous source' do
      changes = write_source('lib/unrecorded.rb', 'class LibraryUtility; end')

      expect(extractor.send(:render_retarget_ids, changes)).to contain_exactly('ShelfController', 'OtherController')
    end

    it 'conservatively selects every controller for an unrecorded deleted Ruby file' do
      expect(extractor.send(:render_retarget_ids, change('lib/removed.rb')))
        .to contain_exactly('ShelfController', 'OtherController')
    end
  end
end
