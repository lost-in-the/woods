# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/js_module_facts'

RSpec.describe Woods::Extractors::JsModuleFacts do
  def facts(source)
    described_class.parse(source)
  end

  describe 'imports' do
    it 'reads default, named, aliased and namespace bindings' do
      result = facts(<<~JS)
        import Widget, { helper, other as renamed } from "./widget"
        import * as ledger from '../ledger'
        import "./side_effect"
      JS

      expect(result.imports).to eq(
        [
          { specifier: '../ledger', names: ['*'], kind: 'static' },
          { specifier: './side_effect', names: [], kind: 'static' },
          { specifier: './widget', names: %w[default helper other], kind: 'static' }
        ]
      )
      expect(result.bindings).to eq(
        'Widget' => ['./widget', 'default'], 'helper' => ['./widget', 'helper'],
        'renamed' => ['./widget', 'other'], 'ledger' => ['../ledger', '*']
      )
    end

    it 'reads type-only imports, a default import named type, dynamic imports and require' do
      result = facts(<<~TS)
        import type { Shape } from "./shape"
        import type from "./type"
        const lazy = () => import("./lazy")
        const legacy = require("./legacy")
      TS

      expect(result.imports.map { |entry| entry.values_at(:specifier, :kind) }).to eq(
        [['./lazy', 'dynamic'], ['./legacy', 'require'], ['./shape', 'static'], ['./type', 'static']]
      )
      expect(result.bindings).to include('type' => ['./type', 'default'], 'Shape' => ['./shape', 'Shape'])
    end

    it 'merges repeated imports of one specifier' do
      result = facts(%(import a from "./x"\nimport { b } from "./x"\n))

      expect(result.imports).to eq([{ specifier: './x', names: %w[b default], kind: 'static' }])
    end

    it 'ignores import.meta and imports inside comments and strings' do
      result = facts(<<~JS)
        // import Ghost from "./ghost"
        const text = 'import Fake from "./fake"'
        const url = import.meta.url
      JS

      expect(result.imports).to eq([])
    end

    it 'does not read a malformed import as one' do
      expect(facts('import Widget from; export default 1').imports).to eq([])
    end
  end

  describe 'exports' do
    it 'reads named declarations and lists' do
      result = facts(<<~TS)
        export const alpha = 1
        export function beta() {}
        export async function gamma() {}
        export class Delta {}
        export { epsilon, zeta as eta }
        export interface Theta {}
        export type Iota = string
      TS

      expect(result.named_exports).to eq(%w[Delta Iota Theta alpha beta epsilon eta gamma])
      expect(result.default_export).to be_nil
      expect(result.default_export?).to be(false)
    end

    it 'names an identifier, function or class default export' do
      expect(facts('const dropdown = () => ({}); export default dropdown').default_export).to eq('dropdown')
      expect(facts('export default function picker() {}').default_export).to eq('picker')
      expect(facts('export default class Ledger extends Base {}').default_export).to eq('Ledger')
    end

    it 'records an anonymous default export without a name' do
      ['export default () => ({ open: false })', 'export default class extends Controller {}',
       'export default { a: 1 }', 'module.exports = {}'].each do |source|
        result = facts(source)
        expect(result.default_export).to be_nil
        expect(result.default_export?).to be(true), source
      end
    end

    it 'reads re-exports as both exports and imports' do
      result = facts(<<~JS)
        export { default as Clipboard, helper } from "./clipboard_controller"
        export * from "./shared"
      JS

      expect(result.named_exports).to eq(%w[Clipboard helper])
      expect(result.imports).to eq(
        [{ specifier: './clipboard_controller', names: %w[default helper], kind: 'reexport' },
         { specifier: './shared', names: ['*'], kind: 'reexport' }]
      )
      expect(result.reexports).to eq('Clipboard' => ['./clipboard_controller', 'default'],
                                     'helper' => ['./clipboard_controller', 'helper'])
    end
  end

  describe 'Stimulus' do
    it 'reads application.register calls with their target identifier' do
      result = facts(<<~JS)
        import { Application } from "@hotwired/stimulus"
        import ClipboardController from "./clipboard_controller"
        const application = Application.start()
        application.register("clipboard", ClipboardController)
        application.register('nested--picker', PickerController)
      JS

      expect(result.stimulus_registrations).to eq(
        [{ name: 'clipboard', target: 'ClipboardController' }, { name: 'nested--picker', target: 'PickerController' }]
      )
    end

    it 'accepts another receiver only when the file imports Stimulus' do
      with_import = facts(%(import { Application } from "@hotwired/stimulus"\nwindow.Hub.register("a", A)\n))
      without = facts('registry.register("a", A)')

      expect(with_import.stimulus_registrations).to eq([{ name: 'a', target: 'A' }])
      expect(without.stimulus_registrations).to eq([])
    end

    it 'reads controller loaders and their directory' do
      result = facts(<<~JS)
        import { eagerLoadControllersFrom, lazyLoadControllersFrom } from "@hotwired/stimulus-loading"
        eagerLoadControllersFrom("controllers", application)
        lazyLoadControllersFrom("widgets/controllers", application)
      JS

      expect(result.stimulus_loaders).to eq(
        [{ function: 'eagerLoadControllersFrom', under: 'controllers' },
         { function: 'lazyLoadControllersFrom', under: 'widgets/controllers' }]
      )
    end

    it 'detects a Stimulus controller class' do
      controller = facts(<<~JS)
        import { Controller } from "@hotwired/stimulus"
        export default class extends Controller {}
      JS
      other = facts('export default class extends Controller {}')

      expect(controller.stimulus_controller_class?).to be(true)
      expect(other.stimulus_controller_class?).to be(false)
    end
  end

  describe 'Alpine' do
    it 'reads data and store registrations, inline or by identifier' do
      result = facts(<<~JS)
        import dropdown from "./dropdown"
        document.addEventListener("alpine:init", () => {
          Alpine.data("dropdown", dropdown)
          Alpine.data('productSelector', (options) => ({ options }))
          window.Alpine.data("legacy", function () { return {} })
          Alpine.store("cart", { items: [] })
        })
      JS

      expect(result.alpine_registrations).to eq(
        [{ kind: 'alpine_data', name: 'dropdown', target: 'dropdown' },
         { kind: 'alpine_data', name: 'productSelector', target: nil },
         { kind: 'alpine_data', name: 'legacy', target: nil },
         { kind: 'alpine_store', name: 'cart', target: nil }]
      )
    end

    it 'reads window function globals and aliases to declared or imported names' do
      result = facts(<<~JS)
        import picker from "./picker"
        import Alpine from "alpinejs"
        function tooltip() { return {} }
        window.dropdown = function () { return {} }
        window.accordion = () => ({})
        window.picker = picker
        window.tooltip = tooltip
        window.Alpine = Alpine
        window.settings = { debug: true }
        window.count = 3
        window.unknown = somethingElse
        if (window.flag == true) {}
      JS

      expect(result.globals).to eq(
        [{ name: 'dropdown', target: nil }, { name: 'accordion', target: nil },
         { name: 'picker', target: 'picker' }, { name: 'tooltip', target: 'tooltip' },
         { name: 'Alpine', target: 'Alpine' }]
      )
    end
  end

  describe 'custom elements' do
    it 'reads a Stencil component tag' do
      result = facts(<<~TSX)
        import { Component, h } from "@stencil/core"
        @Component({
          styleUrl: "shipment-card.css",
          tag: "x-shipment-card",
          shadow: true,
        })
        export class ShipmentCard {}
      TSX

      expect(result.custom_elements).to eq([{ tag: 'x-shipment-card', source: 'stencil', target: nil }])
    end

    it 'ignores a tag key nested deeper than the decorator options' do
      result = facts('@Component({ meta: { tag: "x-inner" } }) class A {}')

      expect(result.custom_elements).to eq([])
    end

    it 'reads customElements.define' do
      result = facts(<<~JS)
        customElements.define("x-ledger-row", LedgerRow)
        window.customElements.define('x-inline', class extends HTMLElement {})
      JS

      expect(result.custom_elements).to eq(
        [{ tag: 'x-ledger-row', source: 'define', target: 'LedgerRow' },
         { tag: 'x-inline', source: 'define', target: nil }]
      )
    end
  end

  it 'returns empty facts for an empty source' do
    result = facts('')

    expect(result.imports).to eq([])
    expect(result.named_exports).to eq([])
    expect(result.default_export?).to be(false)
  end
end
