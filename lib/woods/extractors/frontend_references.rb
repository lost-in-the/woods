# frozen_string_literal: true

require 'set'
require 'strscan'
require_relative 'js_module_registry'
require_relative '../source_file'

module Woods
  module Extractors
    # Links a component or template to the JavaScript modules it names.
    #
    # Server-rendered markup references frontend code by name: an Alpine
    # `x-data="dropdown"`, a Stimulus `data-controller="clipboard"`, a custom
    # element tag `<x-shipment-card>`. {Scanner} finds those names in ERB,
    # HAML, Phlex and ViewComponent source; {#apply_frontend_references}
    # resolves each through {JsModuleRegistry} into a `js_module` edge whose
    # `via` is the reference kind. A name no module registers produces no
    # edge and is listed under `metadata[:unresolved_frontend_references]`.
    #
    # @example
    #   include FrontendReferences
    #   apply_frontend_references(unit, source)
    #   unit.dependencies.last
    #   # => { type: :js_module, target: "app/javascript/alpine/dropdown.js", via: :alpine_data }
    module FrontendReferences
      # Finds frontend names in template or component source: one forward
      # StringScanner pass, byte offsets only.
      class Scanner
        KINDS = %w[alpine_data stimulus_controller custom_element].freeze

        # Where a reference can start. `data` and `controller` matter only as
        # hash keys (`data: { controller: "..." }`), braces track that hash.
        TRIGGER = /(?<![\w-])x[-_]data(?![\w-])|(?<![\w-])data[-_]controller(?![\w-])|\bdata\b|\bcontroller\b|
                   [{}<]|\bregister_element\b|^[ \t]*+%(?=[a-z])/x

        # `"x-data": "v"`, `x-data="v"`, `"x-data" => 'v'`; the value is group 2.
        ATTRIBUTE_VALUE = /["']?\s*+(=>|[=:])\s*+(?:"([^"]*+)"|'([^']*+)')/
        HASH_OPEN = /["']?\s*+(?::|=>)\s*+\{/
        TAG_NAME = /[a-z][a-z0-9]*+(?:-[a-z0-9]++)++(?![\w-])/
        ELEMENT_SYMBOL = /\s*+\(?\s*+:([a-z][a-z0-9_]*+)/
        ALPINE_NAME = /\A\s*+([A-Za-z_$][\w$]*+)\s*+(?:\(|\z)/
        STIMULUS_NAME = /\A[A-Za-z0-9_-]++\z/

        # Literals and keywords that make `x-data` an anonymous scope
        # (`x-data="true"`, Phlex `"x-data": true`), never a component name.
        ALPINE_NON_NAMES = %w[
          true false null undefined this NaN Infinity new typeof void delete in instanceof
          function class async await yield return if else for while do switch case default
          break continue try catch finally throw var let const import export super with
        ].to_set.freeze

        # A source with none of these has no reference; most have none.
        CANDIDATE = /x[-_]data|controller|register_element|[<%][a-z][a-z0-9]*+-/

        # A `controller:` key counts only this close to its `data: {`.
        DATA_HASH_SPAN = 2_000
        MAX_NESTING = 256

        # @param source [String] template or component source
        # @return [Hash{String => Array<String>}] sorted names per kind
        def self.scan(source)
          new(source).scan
        end

        # @param source [String]
        def initialize(source)
          text = source.to_s
          text = text.scrub('?') unless text.valid_encoding?
          @scanner = StringScanner.new(text)
          @found = KINDS.to_h { |kind| [kind, []] }
          @braces = []
        end

        # @return [Hash{String => Array<String>}]
        def scan
          return @found unless @scanner.string.match?(CANDIDATE)

          handle(@scanner.matched) while @scanner.skip_until(TRIGGER)
          @found.transform_values { |names| names.uniq.sort }
        end

        private

        def handle(trigger)
          case trigger
          when '{' then open_brace(:other)
          when '}' then @braces.pop
          when 'data' then open_brace(:data) if @scanner.skip(HASH_OPEN)
          when 'controller' then scan_data_key
          when 'register_element' then scan_registered_element
          when /data\z/ then scan_alpine(trigger)
          when /controller\z/ then scan_stimulus(attribute_value(trigger))
          else scan_tag # `<` or a HAML `%`
          end
        end

        def open_brace(kind)
          @braces.clear if @braces.size >= MAX_NESTING
          @braces.push([kind, @scanner.pos])
        end

        # The quoted value after an attribute or key name. An underscore name
        # (`x_data`) is a Ruby keyword argument, so `=` there is an assignment
        # to a local, not an attribute.
        def attribute_value(trigger)
          return nil unless @scanner.skip(ATTRIBUTE_VALUE)
          return nil if trigger.include?('_') && @scanner[1] == '='

          @scanner[2] || @scanner[3]
        end

        def scan_alpine(trigger)
          name = attribute_value(trigger)&.match(ALPINE_NAME)
          @found['alpine_data'] << name[1] if name && !ALPINE_NON_NAMES.include?(name[1])
        end

        def scan_stimulus(value)
          literal_text(value.to_s).split.each do |name|
            @found['stimulus_controller'] << name if name.match?(STIMULUS_NAME)
          end
        end

        # The value with ERB tags and Ruby interpolations blanked, so a word
        # inside `<%= name %>` is not read as a controller name.
        def literal_text(value)
          return value unless value.include?('<%') || value.include?('#{')

          text = +''
          dynamic = StringScanner.new(value)
          until dynamic.eos?
            if dynamic.skip(/<%/)
              dynamic.skip_until(/%>/) || dynamic.terminate
            elsif dynamic.skip(/#\{/)
              dynamic.skip_until(/\}/) || dynamic.terminate
            else
              text << dynamic.scan(/[^<#]++|[<#]/)
              next
            end
            text << ' '
          end
          text
        end

        # `controller: "name"` directly inside a `data: { ... }` hash.
        def scan_data_key
          kind, opened_at = @braces.last
          return unless kind == :data && @scanner.pos - opened_at <= DATA_HASH_SPAN

          value = @scanner.skip(ATTRIBUTE_VALUE) && @scanner[1] != '=' && (@scanner[2] || @scanner[3])
          scan_stimulus(value) if value
        end

        def scan_tag
          tag = @scanner.scan(TAG_NAME)
          @found['custom_element'] << tag if tag
        end

        # Phlex `register_element :x_shipment_card` renders `<x-shipment-card>`.
        def scan_registered_element
          return unless @scanner.skip(ELEMENT_SYMBOL)

          tag = @scanner[1].tr('_', '-')
          @found['custom_element'] << tag if tag.include?('-')
        end
      end

      # Add a `js_module` edge for each frontend name +source+ references and
      # record the names no module registers. A component's sidecar template
      # (`metadata[:sidecar_template]`, root-relative) is scanned too.
      #
      # @param unit [ExtractedUnit] component or template unit, mutated
      # @param source [String] the source to scan
      # @return [ExtractedUnit]
      def apply_frontend_references(unit, source)
        references = Scanner.scan(source)
        sidecar = sidecar_template_source(unit)
        references = references.merge(Scanner.scan(sidecar)) { |_kind, a, b| (a + b).uniq.sort } if sidecar
        return unit if references.each_value.all?(&:empty?)

        edges, unresolved = resolve_frontend_references(references)
        unit.dependencies = (unit.dependencies + edges).uniq { |dep| dep.values_at(:type, :target, :via) }
        unit.metadata[:unresolved_frontend_references] = unresolved if unresolved.any?
        unit
      end

      private

      # One registry per extractor instance: built from the files on disk
      # when first needed, so every unit of a run resolves against one map.
      def frontend_registry
        @frontend_registry ||= JsModuleRegistry.current
      end

      # @return [String, nil] the sidecar template's contents, when the unit names one that exists
      def sidecar_template_source(unit)
        relative = unit.metadata.is_a?(Hash) && unit.metadata[:sidecar_template]
        return nil unless relative.is_a?(String) && defined?(Rails) && Rails.root

        path = Rails.root.join(relative)
        SourceFile.read(path) if File.file?(path)
      rescue SystemCallError
        nil
      end

      def resolve_frontend_references(references)
        edges = []
        unresolved = []
        references.each do |kind, names|
          names.each do |name|
            target = frontend_registry.resolve(kind, name)
            if target
              edges << { type: :js_module, target: target, via: kind.to_sym }
            else
              unresolved << { kind: kind, name: name }
            end
          end
        end
        [edges, unresolved]
      end
    end
  end
end
