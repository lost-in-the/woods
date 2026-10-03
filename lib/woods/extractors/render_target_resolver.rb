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
    #   result.external   # => [{ name: "ShelfUi::Button", gem: "shelf_ui" }]
    #
    # Slot declarations (`renders_one :header, HeaderComponent`) resolve the
    # same way into +slot_targets+ and +unresolved_slots+. A class name given
    # as a string is looked up from the component class alone, as the
    # framework does.
    #
    class RenderTargetResolver
      # @!attribute targets
      #   @return [Array<String>] sorted identifiers of the components rendered
      # @!attribute unresolved
      #   @return [Array<Hash>] sorted `{ name:, reason: }` for calls that name no component
      # @!attribute external
      #   @return [Array<Hash>] sorted `{ name:, gem: }` for component classes no unit represents
      # @!attribute slot_targets
      #   @return [Array<String>] sorted identifiers of the components slots are declared with
      # @!attribute unresolved_slots
      #   @return [Array<Hash>] sorted `{ name:, reason: }` for slots that name no component
      Result = Struct.new(:targets, :unresolved, :external, :slot_targets, :unresolved_slots, keyword_init: true)

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
      # @param ownership [#call] given a component class, answers +:app+ when
      #   the application defines it, otherwise the name of the gem that does,
      #   or nil when no gem is known
      def initialize(runtime: SourceReferences::RuntimeLookup.new, ownership: ->(_component) { :app })
        @runtime = runtime
        @ownership = ownership
      end

      TEMPLATE_KINDS = %i[constant kit kit_path yielded].freeze
      private_constant :TEMPLATE_KINDS

      # @param component [Class] the rendering component
      # @param source [String] the source of the file that defines it
      # @param fragments [Array<String>] Ruby from the component's templates
      #   ({TemplateRubyFragments}). A compiled template is evaluated in the
      #   component class, so its constants are looked up from that class
      #   alone, not from the modules the class file nests it in.
      # @return [Result]
      def call(component, source, fragments: [])
        run = { component: component, bases: loaded(COMPONENT_BASES), kit: loaded(%w[Phlex::Kit]).first,
                targets: {}, unresolved: {}, slot_targets: {}, unresolved_slots: {}, yielded: [] }

        (RenderCallScan.call(source) + template_candidates(component, fragments))
          .each { |candidate| resolve(candidate, run) }
        run[:yielded].each { |candidate| record(run, candidate.name, yielded_verdict(candidate, run)) }

        result(run)
      end

      private

      def template_candidates(component, fragments)
        scope = [component.name].compact
        fragments.flat_map { |fragment| RenderCallScan.call(fragment) }
                 .select { |candidate| TEMPLATE_KINDS.include?(candidate.kind) }
                 .each { |candidate| candidate.nesting = scope }
      end

      # A component class the application does not define has no unit, so an
      # edge to it would point at nothing. It is reported instead.
      def result(run)
        renders, external_renders = owned(run[:targets], run)
        slots, external_slots = owned(run[:slot_targets], run)
        Result.new(
          targets: renders, unresolved: reasons(run[:unresolved]),
          slot_targets: slots, unresolved_slots: reasons(run[:unresolved_slots]),
          external: (external_renders + external_slots).uniq.sort_by { |entry| entry[:name] }
        )
      end

      # @return [Array(Array<String>, Array<Hash>)] application-owned
      #   identifiers, then `{ name:, gem: }` for the rest
      def owned(resolved, run)
        own_name = run[:component].name
        owners = resolved.sort.reject { |name, _klass| name == own_name }
                         .map { |name, klass| [name, @ownership.call(klass)] }
        app, external = owners.partition { |_name, owner| owner == :app }
        [app.map(&:first), external.map { |name, gem| { name: name, gem: gem } }]
      end

      def reasons(unresolved)
        unresolved.sort.map { |name, reason| { name: name, reason: reason } }
      end

      def resolve(candidate, run)
        case candidate.kind
        when :constant then record(run, candidate.name, lookup(candidate.name, candidate.nesting))
        when :kit then record(run, candidate.name, kit_verdict(candidate, run))
        when :kit_path then record(run, candidate.name, kit_path_verdict(candidate))
        when :yielded then resolve_yielded(candidate, run)
        when :slot, :slot_string
          record(run, candidate.name, lookup(candidate.name, candidate.nesting), :slot_targets, :unresolved_slots)
        end
      end

      # A verdict is a RuntimeLookup result, or nil for a call that is not a
      # render at all.
      def record(run, name, verdict, resolved = :targets, unresolved = :unresolved)
        return unless verdict

        if verdict[:status] != :resolved
          run[unresolved][name] ||= verdict[:reason]
        elsif component_class?(verdict[:value], run)
          run[resolved][verdict[:target]] = verdict[:value]
        else
          run[unresolved][name] ||= 'not_a_component'
        end
      end

      def lookup(name, nesting)
        result = @runtime.call(name, nesting: nesting)
        # The scan names scopes from source text. When one is not a loaded
        # constant there is no lexical scope to search, only the top level.
        result = @runtime.call(name) if result[:reason] == 'unloaded_scope'
        result[:reason] == 'constant_alias' ? follow_alias(name, nesting) : result
      end

      # RuntimeLookup declines a constant whose value is named something else
      # (`Card = Ui::Card`). For a render that is still the component reached,
      # so walk the same tables again and answer with the value's own name.
      def follow_alias(name, nesting)
        scopes = name.start_with?('::') ? [Object] : lexical_scopes(nesting)
        value = nil
        name.delete_prefix('::').split('::').each do |part|
          owner = scopes.find { |scope| @runtime.reflect(scope, :const_defined?, part, false) }
          return { status: :missing, reason: 'constant_missing' } unless owner
          return unknown('autoload_pending') if @runtime.reflect(owner, :autoload?, part, false)

          value = @runtime.reflect(owner, :const_get, part, false)
          return unknown('non_module_constant') unless @runtime.module_object?(value)

          scopes = [value] + @runtime.reflect(value, :ancestors).take_while { |mod| !IDENTICAL.bind(mod).call(Object) }
        end
        canonical = @runtime.reflect(value, :name)
        canonical ? { status: :resolved, target: canonical, value: value } : unknown('anonymous_constant')
      rescue NameError
        unknown('constant_changed')
      end

      def lexical_scopes(nesting)
        modules = nesting.filter_map { |scope| @runtime.call("::#{scope}", allow_private: true)[:value] }
        return [Object] if modules.empty?

        modules + @runtime.reflect(modules.first, :ancestors) + [Object]
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

          result = lookup("::#{kit_name}::#{name}", [])
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
        unknown('no_kit_constant')
      end

      def unknown(reason)
        { status: :unknown, reason: reason }
      end
    end
  end
end
