# frozen_string_literal: true

require_relative '../source_references/runtime_lookup'
require_relative 'render_call_scan'

module Woods
  module Extractors
    # Names the component a render call reaches, the way the running app would.
    #
    # Component source names its targets relative to where it stands:
    # `render TierGrid.new` inside `Billing::V2::ManagePage` means
    # `Billing::V2::TierGrid`, and `Header(title: "x")` in a class that includes
    # a Phlex Kit means that Kit's `Header`. Recording the name as written
    # leaves an edge that points at no unit, although the unit exists.
    #
    # Resolution follows Ruby, in this order:
    #
    # 1. A rendered constant is looked up through the lexical scope of the call
    #    site, then the ancestors of the innermost scope (which is how a Kit the
    #    class includes supplies it), then the top level.
    # 2. A capitalized call (`Header(...)`) is a method, so the lexical scope
    #    does not apply. It is looked up in the Kits among the ancestors of the
    #    rendering class: modules that `extend Phlex::Kit`, or that define a
    #    method of that name.
    # 3. A capitalized call on a block argument (`menu.NavItem(...)`) is tried
    #    against the rendering class's Kits, then against the Kits of the
    #    components the same file renders.
    #
    # Every lookup reads already-loaded constant tables through
    # {SourceReferences::RuntimeLookup}: nothing is autoloaded and no
    # application override runs. A call that resolves to no component class
    # yields no target and is reported in +unresolved+ with the reason. A
    # capitalized call that the runtime shows to be an ordinary method
    # (`Integer("3")`) is neither.
    #
    # @example
    #   result = RenderTargetResolver.new.call(Billing::V2::ManagePage, source)
    #   result.targets    # => ["Billing::V2::TierGrid", "Ui::Header"]
    #   result.unresolved # => [{ name: "Ghost", reason: "constant_missing" }]
    #
    class RenderTargetResolver
      # @!attribute targets
      #   @return [Array<String>] sorted identifiers of the components rendered
      # @!attribute unresolved
      #   @return [Array<Hash>] sorted `{ name:, reason: }` for calls that name no component
      Result = Struct.new(:targets, :unresolved, keyword_init: true)

      # Classes whose descendants are components. Those not loaded are skipped.
      COMPONENT_BASES = %w[
        Phlex::SGML Phlex::HTML Phlex::Component ApplicationComponent ViewComponent::Base
      ].freeze

      SINGLETON_CLASS = Kernel.instance_method(:singleton_class)
      METHOD_DEFINED = Module.instance_method(:method_defined?)
      PRIVATE_METHOD_DEFINED = Module.instance_method(:private_method_defined?)
      IS_A = Module.instance_method(:===)
      IDENTICAL = BasicObject.instance_method(:equal?)
      private_constant :SINGLETON_CLASS, :METHOD_DEFINED, :PRIVATE_METHOD_DEFINED, :IS_A, :IDENTICAL

      # @param runtime [SourceReferences::RuntimeLookup]
      def initialize(runtime: SourceReferences::RuntimeLookup.new)
        @runtime = runtime
      end

      # @param component [Class] the rendering component
      # @param source [String] the source of the file that defines it
      # @return [Result]
      def call(component, source)
        run = { component: component, bases: loaded(COMPONENT_BASES), kit: loaded(%w[Phlex::Kit]).first,
                targets: {}, unresolved: {}, yielded: [] }

        RenderCallScan.call(source).each { |candidate| resolve(candidate, run) }
        run[:yielded].each { |candidate| record(run, candidate.name, yielded_verdict(candidate, run)) }

        own_name = component.name
        Result.new(
          targets: run[:targets].keys.reject { |name| name == own_name }.sort,
          unresolved: run[:unresolved].sort.map { |name, reason| { name: name, reason: reason } }
        )
      end

      private

      def resolve(candidate, run)
        case candidate.kind
        when :constant then record(run, candidate.name, lookup(candidate.name, candidate.nesting))
        when :kit then record(run, candidate.name, kit_verdict(candidate, run))
        when :kit_path then record(run, candidate.name, kit_path_verdict(candidate))
        when :yielded then resolve_yielded(candidate, run)
        end
      end

      # A verdict is a RuntimeLookup result, or nil for a call that is not a
      # render at all.
      def record(run, name, verdict)
        return unless verdict

        if verdict[:status] != :resolved
          run[:unresolved][name] ||= verdict[:reason]
        elsif component_class?(verdict[:value], run)
          run[:targets][verdict[:target]] = verdict[:value]
        else
          run[:unresolved][name] ||= 'not_a_component'
        end
      end

      def lookup(name, nesting)
        result = @runtime.call(name, nesting: nesting)
        # The scan names scopes from source text. When one is not a loaded
        # constant there is no lexical scope to search, only the top level.
        result = @runtime.call(name) if result[:reason] == 'unloaded_scope'
        result
      end

      def kit_verdict(candidate, run)
        klass = rendering_class(candidate, run)
        from_kits(klass, candidate.name, run) || (ordinary_method?(klass, candidate.name) ? nil : no_kit)
      end

      def kit_path_verdict(candidate)
        result = lookup(candidate.name, candidate.nesting)
        return result if result[:status] == :resolved && @runtime.class_object?(result[:value])

        receiver_path, _, method_name = candidate.name.rpartition('::')
        receiver = lookup(receiver_path, candidate.nesting)[:value]
        return nil if receiver && ordinary_method?(SINGLETON_CLASS.bind(receiver).call, method_name)

        result
      end

      def resolve_yielded(candidate, run)
        verdict = from_kits(rendering_class(candidate, run), candidate.name, run)
        verdict ? record(run, candidate.name, verdict) : run[:yielded] << candidate
      end

      # The receiver of a yielded call is usually the component the block was
      # given to, so the Kits of the components this file renders are searched.
      # More than one distinct answer names nothing.
      def yielded_verdict(candidate, run)
        found = run[:targets].sort.filter_map { |_name, klass| from_kits(klass, candidate.name, run) }
        found = found.uniq { |verdict| verdict[:target] }
        found.size == 1 ? found.first : no_kit
      end

      # @return [Hash, nil] the first Kit ancestor's answer, nil when no Kit has the constant
      def from_kits(klass, name, run)
        @runtime.reflect(klass, :ancestors).each do |ancestor|
          next unless kit?(ancestor, name, run)

          kit_name = @runtime.reflect(ancestor, :name)
          next unless kit_name

          result = @runtime.call("::#{kit_name}::#{name}", allow_private: true)
          return result unless result[:status] == :missing
        end
        nil
      end

      def kit?(mod, name, run)
        return false if @runtime.class_object?(mod)

        (run[:kit] && IS_A.bind(run[:kit]).call(mod)) || ordinary_method?(mod, name)
      end

      def rendering_class(candidate, run)
        innermost = candidate.nesting.first
        value = innermost && @runtime.call("::#{innermost}", allow_private: true)[:value]
        value || run[:component]
      end

      def ordinary_method?(mod, name)
        METHOD_DEFINED.bind(mod).call(name) || PRIVATE_METHOD_DEFINED.bind(mod).call(name)
      end

      def component_class?(value, run)
        return false unless @runtime.class_object?(value)

        @runtime.reflect(value, :ancestors).any? do |ancestor|
          run[:bases].any? { |base| IDENTICAL.bind(base).call(ancestor) }
        end
      end

      def loaded(names)
        names.filter_map { |name| @runtime.call("::#{name}")[:value] }
      end

      def no_kit
        { status: :unknown, reason: 'no_kit_constant' }
      end
    end
  end
end
