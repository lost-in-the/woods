# frozen_string_literal: true

require 'prism'
require_relative '../source_file'

module Woods
  module Extractors
    # Resolved filter applicability for a controller or mailer (W-8,
    # woods#758): for each callback in +_process_action_callbacks+, the
    # admitted actions it applies to after +only+/+except+, whether an
    # +if+/+unless+ condition still decides it at request time, and the class
    # or concern that declared it.
    #
    # +only+/+except+ are read from the runtime chain (ActionFilter's
    # +@actions+ Set, or the Rails 6.0 proc's closed-over set; see
    # {SharedUtilityMethods#extract_action_filter_actions}), so an inherited
    # or concern-supplied filter and a +skip_before_action+ scope resolve
    # exactly as Rails runs them. Any other condition (a method name, a proc,
    # a string) is never evaluated: such a filter is +conditional+, and
    # +applies_to+ names the actions it can run on, not the ones it will.
    #
    # The owner is the module whose source declares the filter: the class in
    # whose chain the callback object first appears, or one of the concerns
    # that class includes. A callback that +skip_before_action+ rebuilt with a
    # narrower scope is traced to the declaration it replaced. When no
    # application source declares it (a gem concern, or a macro such as
    # +protect_from_forgery+), the owner is the class whose chain gained it.
    #
    # Including classes provide +extract_callback_conditions+,
    # +extract_action_filter_actions+ and +app_source_file?+ (from
    # {SharedUtilityMethods}); a +source_file_for(klass)+ is used for class
    # sources when defined.
    module FilterApplicability
      # The DSL calls that declare a process-action callback, by callback kind.
      FILTER_DECLARATIONS = %i[before after around].to_h do |kind|
        [kind, %W[#{kind}_action prepend_#{kind}_action append_#{kind}_action]]
      end.freeze

      # Every only/except scope was read from the runtime chain.
      RESOLVED = 'resolved'
      # An if/unless condition Woods does not evaluate also decides the filter.
      CONDITIONAL = 'conditional'

      # @param klass [Class] the controller or mailer the chain belongs to
      # @param callback [ActiveSupport::Callbacks::Callback] one callback of its chain
      # @param actions [Array<String>] the class's admitted actions, in published order
      # @return [Hash] +owner+ (String, nil when no named module is known),
      #   +applies_to+ (Array<String>, a subset of +actions+ in their order) and
      #   +applicability+ ({RESOLVED} or {CONDITIONAL})
      def filter_applicability(klass, callback, actions)
        only_sets = action_scopes(callback, :@if)
        except_sets = action_scopes(callback, :@unless)
        conditional = (only_sets + except_sets).include?(nil)
        applies_to = actions.map(&:to_s).select do |action|
          only_sets.compact.all? { |set| set.include?(action) } && except_sets.compact.none? { |set| set.include?(action) }
        end

        { owner: filter_owner(klass, callback), applies_to: applies_to,
          applicability: conditional ? CONDITIONAL : RESOLVED }
      end

      private

      # @return [Array<Array<String>, nil>] one entry per condition: the action
      #   set of an only/except scope, nil for any other condition
      def action_scopes(callback, ivar)
        Array(callback.instance_variable_get(ivar)).map { |condition| extract_action_filter_actions(condition) }
      end

      # @return [String, nil]
      def filter_owner(klass, callback)
        classes = chain_classes(klass)
        index = origin_index(classes, callback)
        return klass.name unless index

        loop do
          declarer = declaring_module(classes[index], callback)
          return declarer.name if declarer

          replaced = classes[index + 1] && chain_of(classes[index + 1]).find { |other| same_filter?(other, callback) }
          break unless replaced

          callback = replaced
          index = origin_index(classes, callback)
        end
        classes[index].name
      end

      # The class and its superclasses that carry a callback chain, nearest first.
      def chain_classes(klass)
        return [klass] unless klass.respond_to?(:ancestors)

        klass.ancestors.grep(Class).select { |mod| mod.respond_to?(:_process_action_callbacks) }
      end

      # The farthest class whose chain holds this very callback object: where
      # it was declared, or where skip_before_action rebuilt it.
      def origin_index(classes, callback)
        classes.rindex { |mod| chain_of(mod).any? { |other| other.equal?(callback) } }
      end

      def chain_of(mod)
        (@filter_chains ||= {}.compare_by_identity)[mod] ||= mod._process_action_callbacks.to_a
      end

      def same_filter?(other, callback)
        other.kind == callback.kind && raw_filter_of(other) == raw_filter_of(callback)
      end

      def raw_filter_of(callback)
        callback.respond_to?(:raw_filter) ? callback.raw_filter : callback.filter
      end

      # The class itself, then the modules it includes or prepends (those
      # between it and its superclass), whose application source declares
      # the callback.
      def declaring_module(klass, callback)
        group = klass.respond_to?(:ancestors) ? klass.ancestors.take_while { |mod| !mod.equal?(klass.superclass) } : []
        ([klass] + (group - [klass])).find do |mod|
          owner_source_paths(mod).any? { |path| declares_filter?(path, callback) }
        end
      end

      def declares_filter?(path, callback)
        filter = raw_filter_of(callback)
        return File.expand_path(filter.source_location.to_a.first.to_s) == File.expand_path(path) if filter.is_a?(Proc)
        return false unless filter.is_a?(Symbol) || filter.is_a?(String)

        filter_declarations(path).key?([callback.kind.to_sym, filter.to_s])
      end

      # The application source files that define +mod+: a class's convention
      # or constant location; for a module, also the file of its
      # ActiveSupport::Concern +included+ block and of the methods it defines
      # itself, because +const_source_location+ can report the autoload
      # registration site rather than the file that defined the constant. A
      # class's own methods are not consulted: a concern's +included+ block
      # can define them from the concern's file.
      #
      # @return [Array<String>]
      def owner_source_paths(mod)
        return [] unless mod.respond_to?(:name) && mod.name

        (@owner_source_paths ||= {}.compare_by_identity)[mod] ||= [
          (source_file_for(mod) if mod.is_a?(Class) && respond_to?(:source_file_for, true)),
          constant_source_path(mod.name),
          *(mod.is_a?(Class) ? [] : [included_block_path(mod), *own_method_paths(mod)])
        ].compact.uniq.select { |path| app_source_file?(path) }
      end

      def included_block_path(mod)
        block = mod.instance_variable_get(:@_included_block) if mod.instance_variable_defined?(:@_included_block)
        block.is_a?(Proc) ? block.source_location&.first : nil
      end

      def own_method_paths(mod)
        names = mod.public_instance_methods(false) + mod.protected_instance_methods(false) +
                mod.private_instance_methods(false)
        names.filter_map { |name| mod.instance_method(name).source_location&.first }
      rescue StandardError
        []
      end

      def constant_source_path(name)
        return nil unless Object.respond_to?(:const_source_location)

        Object.const_source_location(name)&.first
      rescue StandardError
        nil
      end

      # Filter declarations in one source file, parsed once per extractor.
      #
      # @param path [String]
      # @return [Hash{Array(Symbol, String) => Integer}] `[kind, name]` to the
      #   line of its first declaration
      def filter_declarations(path)
        (@filter_declarations ||= {})[path] ||= begin
          parsed = Prism.parse(SourceFile.read(path))
          sites = {}
          collect_filter_declarations(parsed.value, sites) if parsed.success?
          sites
        end
      end

      # @return [void]
      def collect_filter_declarations(node, sites)
        if node.is_a?(Prism::CallNode) && node.receiver.nil? && (kind = filter_declaration_kind(node.name))
          Array(node.arguments&.arguments).grep(Prism::SymbolNode).each do |symbol|
            sites[[kind, symbol.unescaped]] ||= node.location.start_line
          end
        end
        node.compact_child_nodes.each { |child| collect_filter_declarations(child, sites) }
      end

      # @param name [Symbol] a called method's name
      # @return [Symbol, nil] the callback kind it declares
      def filter_declaration_kind(name)
        FILTER_DECLARATIONS.find { |_kind, methods| methods.include?(name.to_s) }&.first
      end
    end
  end
end
