# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extractors/js_module_registry'

RSpec.describe Woods::Extractors::JsModuleRegistry do
  def registry(sources)
    described_class.build(sources, directories: %w[app/assets/javascripts app/javascript])
  end

  stimulus_import = %(import { Controller } from "@hotwired/stimulus"\n)

  describe 'import resolution' do
    let(:built) do
      registry(
        'app/javascript/application.js' => <<~JS,
          import "./controllers"
          import picker from "./widgets/picker"
          import { total } from "../javascript/ledger/total.js"
          import shared from "@/shared/format"
          import clip from "controllers/clipboard_controller"
          import Alpine from "alpinejs"
          import gone from "./missing"
          import escape from "../../../../etc/passwd"
        JS
        'app/javascript/controllers/index.js' => '',
        'app/javascript/controllers/clipboard_controller.js' => '',
        'app/javascript/widgets/picker.tsx' => '',
        'app/javascript/ledger/total.ts' => '',
        'app/javascript/shared/format.js' => ''
      )
    end

    it 'resolves relative, index, extension-swapped, aliased and root-relative specifiers to module paths' do
      resolved = built.resolved_imports('app/javascript/application.js').to_h { |i| [i[:specifier], i[:resolved]] }

      expect(resolved).to eq(
        './controllers' => 'app/javascript/controllers/index.js',
        './widgets/picker' => 'app/javascript/widgets/picker.tsx',
        '../javascript/ledger/total.js' => 'app/javascript/ledger/total.ts',
        '@/shared/format' => 'app/javascript/shared/format.js',
        'controllers/clipboard_controller' => 'app/javascript/controllers/clipboard_controller.js',
        'alpinejs' => nil,
        './missing' => nil,
        '../../../../etc/passwd' => nil
      )
    end
  end

  describe 'Stimulus names' do
    it 'derives names from the controllers directory convention' do
      built = registry(
        'app/javascript/controllers/clipboard_controller.js' => '',
        'app/javascript/controllers/ledgers/line_item_controller.ts' => '',
        'app/javascript/controllers/date-picker-controller.js' => '',
        'app/javascript/controllers/index.js' => '',
        'app/javascript/widgets/orphan_controller.js' => ''
      )

      expect(built.resolve('stimulus_controller', 'clipboard'))
        .to eq('app/javascript/controllers/clipboard_controller.js')
      expect(built.resolve('stimulus_controller', 'ledgers--line-item'))
        .to eq('app/javascript/controllers/ledgers/line_item_controller.ts')
      expect(built.resolve('stimulus_controller', 'date-picker'))
        .to eq('app/javascript/controllers/date-picker-controller.js')
      expect(built.resolve('stimulus_controller', 'orphan')).to be_nil
      expect(built.kind('app/javascript/controllers/clipboard_controller.js')).to eq('stimulus_controller')
      expect(built.kind('app/javascript/controllers/index.js')).to eq('module')
    end

    it 'derives names under a directory a controller loader names' do
      built = registry(
        'app/javascript/application.js' => 'lazyLoadControllersFrom("widgets/behaviors", application)',
        'app/javascript/widgets/behaviors/toggle_controller.js' => ''
      )

      expect(built.resolve('stimulus_controller', 'toggle'))
        .to eq('app/javascript/widgets/behaviors/toggle_controller.js')
    end

    it 'resolves an explicit registration through the import, and prefers it to the convention' do
      built = registry(
        'app/javascript/controllers/index.js' => <<~JS,
          import { application } from "./application"
          import Copier from "../widgets/copier"
          application.register("clipboard", Copier)
        JS
        'app/javascript/controllers/application.js' => '',
        'app/javascript/controllers/clipboard_controller.js' => '',
        'app/javascript/widgets/copier.js' => "#{stimulus_import}export default class extends Controller {}"
      )

      expect(built.resolve('stimulus_controller', 'clipboard')).to eq('app/javascript/widgets/copier.js')
      expect(built.kind('app/javascript/widgets/copier.js')).to eq('stimulus_controller')
      expect(built.registered_names('app/javascript/widgets/copier.js'))
        .to eq([{ kind: 'stimulus_controller', name: 'clipboard', source: 'registration' }])
      expect(built.registrations_in('app/javascript/controllers/index.js'))
        .to eq([{ kind: 'stimulus_controller', name: 'clipboard', module: 'app/javascript/widgets/copier.js' }])
    end

    it 'follows a barrel re-export to the defining module' do
      built = registry(
        'app/javascript/setup.js' => <<~JS,
          import { Clipboard } from "./controllers"
          application.register("clipboard", Clipboard)
        JS
        'app/javascript/controllers/index.js' => 'export { default as Clipboard } from "./clip"',
        'app/javascript/controllers/clip.js' => ''
      )

      expect(built.resolve('stimulus_controller', 'clipboard')).to eq('app/javascript/controllers/clip.js')
    end

    it 'lands a registration of a package export on the registering module' do
      built = registry(
        'app/javascript/setup.js' => <<~JS
          import { Dropdown } from "stimulus-kit"
          application.register("dropdown", Dropdown)
        JS
      )

      expect(built.resolve('stimulus_controller', 'dropdown')).to eq('app/javascript/setup.js')
    end
  end

  describe 'Alpine names' do
    let(:built) do
      registry(
        'app/javascript/alpine/index.js' => <<~JS,
          import dropdown from "./dropdown"
          import picker from "./picker"
          Alpine.data("dropdown", dropdown)
          Alpine.data("inlineThing", () => ({}))
          Alpine.store("cart", { items: [] })
          window.picker = picker
        JS
        'app/javascript/alpine/dropdown.js' => 'export default () => ({ open: false })',
        'app/javascript/alpine/picker.js' => 'export default function picker() { return {} }',
        'app/assets/javascripts/legacy.js' => 'window.accordion = function () { return {} }'
      )
    end

    it 'maps data names to the defining module, inline registrations to the registering module' do
      expect(built.resolve('alpine_data', 'dropdown')).to eq('app/javascript/alpine/dropdown.js')
      expect(built.resolve('alpine_data', 'inlineThing')).to eq('app/javascript/alpine/index.js')
      expect(built.resolve('alpine_data', 'picker')).to eq('app/javascript/alpine/picker.js')
      expect(built.resolve('alpine_data', 'accordion')).to eq('app/assets/javascripts/legacy.js')
      expect(built.resolve('alpine_store', 'cart')).to eq('app/javascript/alpine/index.js')
      expect(built.resolve('alpine_data', 'nope')).to be_nil
    end

    it 'classifies the modules' do
      expect(built.kind('app/javascript/alpine/dropdown.js')).to eq('alpine_data')
      expect(built.kind('app/javascript/alpine/index.js')).to eq('alpine_data')
      expect(built.registered_names('app/javascript/alpine/picker.js'))
        .to eq([{ kind: 'alpine_data', name: 'picker', source: 'global' }])
    end

    it 'prefers Alpine.data to a window global of the same name' do
      built = registry(
        'app/javascript/a.js' => 'window.dropdown = function () {}',
        'app/javascript/b.js' => 'Alpine.data("dropdown", () => ({}))'
      )

      expect(built.resolve('alpine_data', 'dropdown')).to eq('app/javascript/b.js')
    end
  end

  describe 'custom elements' do
    it 'maps Stencil tags and defined elements to their modules' do
      built = registry(
        'app/javascript/components/shipment-card.tsx' => '@Component({ tag: "x-shipment-card" }) export class Card {}',
        'app/javascript/elements/index.js' => <<~JS,
          import LedgerRow from "./ledger_row"
          customElements.define("x-ledger-row", LedgerRow)
        JS
        'app/javascript/elements/ledger_row.js' => 'export default class LedgerRow extends HTMLElement {}'
      )

      expect(built.resolve('custom_element', 'x-shipment-card')).to eq('app/javascript/components/shipment-card.tsx')
      expect(built.resolve('custom_element', 'x-ledger-row')).to eq('app/javascript/elements/ledger_row.js')
      expect(built.kind('app/javascript/components/shipment-card.tsx')).to eq('stencil_component')
      expect(built.kind('app/javascript/elements/ledger_row.js')).to eq('custom_element')
    end
  end

  describe 'ambiguity' do
    it 'resolves no module when two register one name at the same precedence' do
      built = registry(
        'app/javascript/a.js' => 'Alpine.data("dropdown", () => ({}))',
        'app/javascript/b.js' => 'Alpine.data("dropdown", () => ({}))'
      )

      expect(built.resolve('alpine_data', 'dropdown')).to be_nil
      expect(built.ambiguous_names).to eq(
        [{ kind: 'alpine_data', name: 'dropdown', modules: %w[app/javascript/a.js app/javascript/b.js] }]
      )
      expect(built.registered_names('app/javascript/a.js')).to eq([])
    end
  end

  describe '#name_map' do
    it 'is sorted, holds only the kinds templates reference, and is equal for equal trees' do
      sources = {
        'app/javascript/controllers/b_controller.js' => '',
        'app/javascript/controllers/a_controller.js' => '',
        'app/javascript/alpine.js' => 'Alpine.data("zeta", () => ({})); Alpine.store("cart", {})'
      }
      map = registry(sources).name_map

      expect(map).to eq(
        'alpine_data' => { 'zeta' => 'app/javascript/alpine.js' },
        'stimulus_controller' => { 'a' => 'app/javascript/controllers/a_controller.js',
                                   'b' => 'app/javascript/controllers/b_controller.js' }
      )
      expect(JSON.generate(map)).to eq(JSON.generate(registry(sources.to_a.reverse.to_h).name_map))
    end
  end

  describe 'published names' do
    around do |example|
      Dir.mktmpdir { |dir| (@root = dir) && example.run }
    end

    def write(relative, contents)
      path = File.join(@root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    def publish(units)
      units.each_with_index do |unit, index|
        write("index/js_modules/unit_#{index}.json", JSON.generate(unit))
      end
      write('index/js_modules/_index.json', JSON.generate([{ 'identifier' => 'ignored' }]))
    end

    it 'reports no change when the published units carry the current map' do
      write('app/javascript/controllers/clipboard_controller.js', '')
      publish([{ 'identifier' => 'app/javascript/controllers/clipboard_controller.js',
                 'metadata' => { 'registered_names' => [{ 'kind' => 'stimulus_controller', 'name' => 'clipboard',
                                                          'source' => 'filename' }] } }])

      expect(described_class.names_changed_since?(File.join(@root, 'index'), @root)).to be(false)
    end

    it 'reports a change when a name was added, removed or moved' do
      write('app/javascript/controllers/clipboard_controller.js', '')
      publish([{ 'identifier' => 'app/javascript/controllers/old_controller.js',
                 'metadata' => { 'registered_names' => [{ 'kind' => 'stimulus_controller', 'name' => 'clipboard',
                                                          'source' => 'registration' }] } }])

      expect(described_class.names_changed_since?(File.join(@root, 'index'), @root)).to be(true)
    end

    it 'ignores store names, which no template edge uses' do
      write('app/javascript/stores.js', 'Alpine.store("cart", {})')

      expect(described_class.names_changed_since?(File.join(@root, 'index'), @root)).to be(false)
    end

    it 'treats a missing index directory as an empty published map' do
      expect(described_class.names_changed_since?(File.join(@root, 'index'), @root)).to be(false)
      write('app/javascript/controllers/clipboard_controller.js', '')
      expect(described_class.names_changed_since?(File.join(@root, 'index'), @root)).to be(true)
    end
  end

  describe '.current' do
    it 'reads the configured tree and reuses the registry until a file changes' do
      Dir.mktmpdir do |root|
        path = File.join(root, 'app/javascript/controllers/clipboard_controller.js')
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, '')

        first = described_class.current(root)
        expect(described_class.current(root)).to equal(first)
        expect(first.paths).to eq(['app/javascript/controllers/clipboard_controller.js'])

        File.write(path, 'export default 1')
        expect(described_class.current(root)).not_to equal(first)
      end
    end

    it 'skips analysis of a file over the analysis ceiling but still lists it' do
      Dir.mktmpdir do |root|
        path = File.join(root, 'app/javascript/huge.js')
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "Alpine.data('big', () => ({}))\n#{'x' * described_class::MAX_ANALYZED_BYTES}")

        built = described_class.current(root)
        expect(built.paths).to eq(['app/javascript/huge.js'])
        expect(built.analysis_omitted?('app/javascript/huge.js')).to be(true)
        expect(built.resolve('alpine_data', 'big')).to be_nil
      end
    end
  end
end
