# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/js_module_extractor'

RSpec.describe Woods::Extractors::JsModuleExtractor do
  include_context 'extractor setup'

  around do |example|
    original = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    example.run
  ensure
    Woods.configuration = original
  end

  def unit_for(units, identifier)
    units.find { |unit| unit.identifier == identifier }
  end

  it 'returns no units when the app has no JavaScript' do
    expect(described_class.new.extract_all).to eq([])
  end

  describe '#extract_all' do
    before do
      create_file('app/javascript/application.js', <<~JS)
        import "./controllers"
        import Alpine from "alpinejs"
        import dropdown from "./alpine/dropdown"
        Alpine.data("dropdown", dropdown)
      JS
      create_file('app/javascript/controllers/index.js', <<~JS)
        import { application } from "./application"
        import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
        eagerLoadControllersFrom("controllers", application)
      JS
      create_file('app/javascript/controllers/application.js', <<~JS)
        import { Application } from "@hotwired/stimulus"
        export const application = Application.start()
      JS
      create_file('app/javascript/controllers/clipboard_controller.js', <<~JS)
        import { Controller } from "@hotwired/stimulus"
        export default class extends Controller {
          copy() {}
        }
      JS
      create_file('app/javascript/alpine/dropdown.js', "export default () => ({ open: false })\n")
      create_file('app/javascript/components/shipment-card.tsx', <<~TSX)
        import { Component, h } from "@stencil/core"
        @Component({ tag: "x-shipment-card", shadow: true })
        export class ShipmentCard {}
      TSX
      create_file('app/javascript/vendor/chart.js', 'export default 1')
      create_file('app/assets/javascripts/legacy.js', 'window.accordion = function () { return {} }')
    end

    let(:units) { described_class.new.extract_all }

    it 'emits one js_module unit per source file, identified by its root-relative path' do
      expect(units.map(&:type).uniq).to eq([:js_module])
      expect(units.map(&:identifier)).to eq(
        %w[
          app/assets/javascripts/legacy.js
          app/javascript/alpine/dropdown.js
          app/javascript/application.js
          app/javascript/components/shipment-card.tsx
          app/javascript/controllers/application.js
          app/javascript/controllers/clipboard_controller.js
          app/javascript/controllers/index.js
        ]
      )
    end

    it 'stores the file as source and its absolute path as file_path' do
      unit = unit_for(units, 'app/javascript/alpine/dropdown.js')

      expect(unit.source_code).to eq("export default () => ({ open: false })\n")
      expect(unit.file_path).to eq(File.join(tmp_dir, 'app/javascript/alpine/dropdown.js'))
      expect(unit.namespace).to eq('app/javascript/alpine')
    end

    it 'records exports, imports, kind and language' do
      app = unit_for(units, 'app/javascript/application.js')
      card = unit_for(units, 'app/javascript/components/shipment-card.tsx')

      expect(app.metadata).to include(
        kind: 'module', language: 'javascript', default_export: nil, has_default_export: false, named_exports: [],
        loc: 4
      )
      expect(app.metadata[:imports]).to eq(
        [{ specifier: './alpine/dropdown', resolved: 'app/javascript/alpine/dropdown.js', names: ['default'],
           kind: 'static' },
         { specifier: './controllers', resolved: 'app/javascript/controllers/index.js', names: [], kind: 'static' },
         { specifier: 'alpinejs', resolved: nil, names: ['default'], kind: 'static' }]
      )
      expect(card.metadata).to include(kind: 'stencil_component', language: 'typescript',
                                       named_exports: ['ShipmentCard'])
    end

    it 'records the names each module is registered under' do
      expect(unit_for(units, 'app/javascript/controllers/clipboard_controller.js').metadata).to include(
        kind: 'stimulus_controller',
        registered_names: [{ kind: 'stimulus_controller', name: 'clipboard', source: 'filename' }]
      )
      expect(unit_for(units, 'app/javascript/alpine/dropdown.js').metadata).to include(
        kind: 'alpine_data', has_default_export: true,
        registered_names: [{ kind: 'alpine_data', name: 'dropdown', source: 'registration' }]
      )
      expect(unit_for(units, 'app/javascript/components/shipment-card.tsx').metadata[:registered_names])
        .to eq([{ kind: 'custom_element', name: 'x-shipment-card', source: 'stencil' }])
      expect(unit_for(units, 'app/assets/javascripts/legacy.js').metadata[:registered_names])
        .to eq([{ kind: 'alpine_data', name: 'accordion', source: 'global' }])
    end

    it 'records registrations a module makes for another module, and controller loaders' do
      expect(unit_for(units, 'app/javascript/application.js').metadata[:registers])
        .to eq([{ kind: 'alpine_data', name: 'dropdown', module: 'app/javascript/alpine/dropdown.js' }])
      expect(unit_for(units, 'app/javascript/controllers/index.js').metadata[:stimulus_loaders])
        .to eq([{ function: 'eagerLoadControllersFrom', under: 'controllers' }])
      expect(unit_for(units, 'app/javascript/alpine/dropdown.js').metadata).not_to include(:registers,
                                                                                           :stimulus_loaders)
    end

    it 'emits an import edge per resolved local import, sorted, and none for packages' do
      expect(unit_for(units, 'app/javascript/application.js').dependencies).to eq(
        [{ type: :js_module, target: 'app/javascript/alpine/dropdown.js', via: :import },
         { type: :js_module, target: 'app/javascript/controllers/index.js', via: :import }]
      )
      expect(unit_for(units, 'app/javascript/alpine/dropdown.js').dependencies).to eq([])
    end

    it 'is byte-identical across repeat runs' do
      again = described_class.new.extract_all

      expect(JSON.generate(again.map(&:to_h).map { |h| h.except(:extracted_at) }))
        .to eq(JSON.generate(units.map(&:to_h).map { |h| h.except(:extracted_at) }))
    end
  end

  describe 'source size cap' do
    it 'omits the source of a file over the cap and records its size' do
      body = "export const big = 1\n#{'// padding\n' * 20_000}"
      create_file('app/javascript/big.js', body)

      unit = described_class.new.extract_all.first

      expect(body.bytesize).to be > described_class::MAX_SOURCE_BYTES
      expect(unit.source_code).to eq('')
      expect(unit.metadata).to include(source_omitted: true, source_bytes: body.bytesize, named_exports: ['big'])
    end

    it 'keeps the source of a file under the cap and does not flag it' do
      create_file('app/javascript/small.js', 'export const small = 1')

      unit = described_class.new.extract_all.first

      expect(unit.metadata).to include(source_bytes: 22)
      expect(unit.metadata).not_to include(:source_omitted)
    end
  end

  describe '#extract_js_module_file' do
    it 'extracts one file with names resolved against the whole tree' do
      create_file('app/javascript/index.js', %(import d from "./dropdown"\nAlpine.data("dropdown", d)\n))
      path = create_file('app/javascript/dropdown.js', 'export default () => ({})')

      unit = described_class.new.extract_js_module_file(path)

      expect(unit.identifier).to eq('app/javascript/dropdown.js')
      expect(unit.metadata[:registered_names]).to eq([{ kind: 'alpine_data', name: 'dropdown',
                                                        source: 'registration' }])
    end

    it 'returns nil for a path that is not module source' do
      path = create_file('app/javascript/vendor/chart.js', 'export default 1')

      expect(described_class.new.extract_js_module_file(path)).to be_nil
      expect(described_class.new.extract_js_module_file(File.join(tmp_dir, 'app/javascript/absent.js'))).to be_nil
    end
  end

  it 'follows configured globs' do
    Woods.configuration.javascript_paths = ['frontend/**/*.ts']
    create_file('frontend/widgets/picker.ts', 'export const picker = 1')
    create_file('app/javascript/ignored.js', 'export default 1')

    expect(described_class.new.extract_all.map(&:identifier)).to eq(['frontend/widgets/picker.ts'])
  end

  it 'reads multibyte source under a non-UTF-8 default external encoding' do
    create_file('app/javascript/label.js', "export const label = 'café'\n")
    previous = Encoding.default_external
    begin
      Encoding.default_external = Encoding::US_ASCII
      unit = described_class.new.extract_all.first
      expect(unit.source_code.encoding).to eq(Encoding::UTF_8)
      expect(unit.metadata[:named_exports]).to eq(['label'])
    ensure
      Encoding.default_external = previous
    end
  end
end
