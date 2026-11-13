# frozen_string_literal: true

require 'prism'
require 'set'
require_relative '../method_table'
require_relative '../parse_cache'

module Woods
  module MCP
    module LookupMember
      # Which definition of a member its owner responds to, read in Ruby's
      # method resolution order as far as the published index records it.
      #
      # The order, nearest first, for each unit of the owner's superclass
      # chain (the owner, then the parent its `:inheritance` edge or
      # `parent_class` names, and so on):
      #
      # 1. modules the unit's own body prepends (`prepend P` read by a Prism
      #    walk), when P's source is inlined;
      # 2. the unit's own body;
      # 3. the concerns inlined at this level: the inlined concerns of the
      #    unit that its parent's unit does not also inline (Ruby skips a
      #    module a superclass already includes).
      #
      # Within one level, the order of the inlined concerns is Ruby's only
      # where the extractor writes them in `included_modules` order (a model,
      # nearest first). A controller's are sorted by name, so two of its
      # concerns that define the name are reported as candidates, not ranked.
      #
      # What the index cannot settle is stated as a caveat: a prepended
      # module whose source is not inlined, and a chain that stops at a parent
      # that is not a published unit when the answer is an inlined concern
      # of the last unit read.
      class Resolution
        # Superclass levels read at most (cycle-safe besides).
        MAX_DEPTH = 16

        # Parents that end an application chain: framework roots that hold no
        # application definition.
        FRAMEWORK_ROOTS = %w[Object BasicObject ActiveRecord::Base ActionController::Base ActionController::API
                             ActionController::Metal ActionMailer::Base ActiveJob::Base].freeze

        # Unit types whose inlined concern blocks are written in
        # `included_modules` order (ModelExtractor#extract_included_modules).
        # ControllerExtractor#detect_included_concerns sorts them by name.
        ORDERED_TYPES = %w[model].freeze

        # Unit types whose extractor inlines concerns, every concern of the
        # whole ancestry (`included_modules`). The level of an inlined concern
        # is read off which units of the chain inline it, so the walk from
        # such a unit continues only through units of these types.
        INLINING_TYPES = %w[model controller].freeze

        # One definition of the member. +unit+ is the published unit whose
        # source holds the entry's lines; +level+ indexes the superclass chain;
        # +origin+ is :own, :concern or :prepended.
        Candidate = Struct.new(:entry, :unit, :level, :origin, :concern, keyword_init: true)

        # Definitions of equal standing. An unordered group with several
        # candidates cannot be ranked; +extras+ are the definitions each
        # candidate's own body overrides.
        Group = Struct.new(:candidates, :ordered, :extras)

        # @return [Array<Hash>] the owner's unit, then each superclass unit read
        attr_reader :chain
        # @return [Candidate, nil] the definition Ruby calls, when established
        attr_reader :chosen
        # @return [Array<Candidate>, nil] definitions the index cannot rank
        attr_reader :ambiguous
        # @return [Array<Candidate>] definitions the answer overrides
        attr_reader :overridden
        # @return [Array<String>] what the index could not establish
        attr_reader :caveats

        # @param unit [Hash] the owner's published unit
        # @param reference [Reference]
        # @param find_unit [#call, nil] (identifier, type) => published unit or nil
        def initialize(unit, reference, find_unit: nil)
          @unit = unit
          @reference = reference
          @find_unit = find_unit
          @caveats = []
          @overridden = []
        end

        # @return [Resolution, nil] nil when no definition was found
        def call
          read_chain
          groups = levels.flat_map(&:last)
          index = groups.index { |group| group.candidates.any? }
          return nil unless index

          settle(groups, index)
          self
        end

        # @return [Integer] the chain level of the answer
        def level
          (chosen || ambiguous.first).level
        end

        private

        def settle(groups, index)
          group = groups[index]
          later = groups.drop(index + 1).flat_map { |other| other.candidates + other.extras }
          if !group.ordered && group.candidates.size > 1
            @ambiguous = group.candidates
            @overridden = group.extras + later
          else
            @chosen = group.candidates.first
            @overridden = group.candidates.drop(1) + group.extras + later
          end
          state_caveats
        end

        # [level, groups] for each unit of the chain, nearest first.
        def levels
          names = @chain.map { |unit| MethodTable.named_blocks(lines_of(unit)).map(&:last) }
          @unpublished_prepends = []
          @chain.each_with_index.map do |unit, level|
            here = level + 1 < @chain.size ? names[level] - names[level + 1] : names[level]
            prepended, unmatched = prepends(unit, here)
            @unpublished_prepends << [level, unit, unmatched] unless unmatched.empty?
            groups = prepended.map { |concern| ordered_group(concern_candidates(concern, level, :prepended)) }
            groups << ordered_group(own_candidates(unit, level))
            groups.concat(included_groups(here - prepended, level, names.first))
            [level, groups]
          end
        end

        def ordered_group(candidates)
          Group.new(candidates, true, [])
        end

        def included_groups(concerns, level, order)
          concerns = concerns.sort_by { |concern| order.index(concern) || order.size }
          per_concern = concerns.map { |concern| concern_candidates(concern, level, :concern) }
          return per_concern.map { |candidates| ordered_group(candidates) } if ORDERED_TYPES.include?(@unit['type'])

          found = per_concern.reject(&:empty?)
          [Group.new(found.map(&:first), false, found.flat_map { |candidates| candidates.drop(1) })]
        end

        # The unit's own definitions of the member, latest first.
        def own_candidates(unit, level)
          class_methods = ConcernClassMethods.own_lines(unit['source_code'], unit['identifier'])
          entries = LookupMember.methods_of(unit).select do |entry|
            entry['name'] == @reference.name && !entry['file_unit'] && entry['owner'] == unit['identifier'] &&
              @reference.kind?(entry) && !class_methods.include?(entry['line'])
          end
          candidates(entries, unit, level, :own, nil)
        end

        # An inlined concern's definitions of the member, latest first, read
        # from the owner's own source where it inlines the concern.
        def concern_candidates(concern, level, origin)
          unit = blocks_of(@unit).include?(concern) ? @unit : @chain[level]
          class_methods = ConcernClassMethods.lines(unit['source_code'])
          entries = LookupMember.methods_of(unit).select do |entry|
            entry['name'] == @reference.name && entry['file_unit'] == concern && entry['owner'] == concern &&
              @reference.concern_kind?(entry, class_methods)
          end
          candidates(entries, unit, level, origin, concern)
        end

        def candidates(entries, unit, level, origin, concern)
          entries.sort_by { |entry| -entry['line'].to_i }.map do |entry|
            Candidate.new(entry: @reference.as_named(entry), unit: unit, level: level, origin: origin,
                          concern: concern)
          end
        end

        def blocks_of(unit)
          (@blocks ||= {})[unit['identifier']] ||= MethodTable.named_blocks(lines_of(unit)).map(&:last)
        end

        def lines_of(unit)
          source = unit['source_code']
          source.is_a?(String) ? source.lines(chomp: true) : []
        end

        # The inlined concerns the unit's own body prepends, nearest first,
        # and the prepended constants whose source is not inlined at this level.
        # A written `prepend` of a concern first inlined at this level puts it
        # before the body. One a superclass already has is a no-op for an
        # `ActiveSupport::Concern` (`prepend_features` returns early) and is
        # prepended again for a plain module.
        def prepends(unit, here)
          known = blocks_of(unit)
          written = Mixins.calls(unit['source_code'], unit['identifier'], :prepend)
          matched = written.map { |name, scopes| Mixins.resolve(name, scopes, known) }
          prepended = matched.compact.uniq.select { |concern| here.include?(concern) || !active_concern?(concern) }
          [prepended, written.reject.with_index { |_, index| matched[index] }.map(&:first)]
        end

        # Whether the inlined module's own body extends ActiveSupport::Concern.
        def active_concern?(concern)
          text = concern_sources.to_h[concern]
          Mixins.calls(text, concern, :extend).any? { |name, _| name.delete_prefix('::') == 'ActiveSupport::Concern' }
        end

        # Whether +concern+ is shown to be mixed in at a level Woods read: an
        # `include` or `prepend` of it written directly in the body of a unit
        # of the chain, or in the module body of an inlined concern that is
        # itself shown (an `ActiveSupport::Concern` dependency, or a module
        # including another). The written constant is resolved lexically
        # against the concerns the owner inlines ({Mixins.resolve}).
        def shown?(concern, seen = Set.new)
          return false unless seen.add?(concern)

          known = blocks_of(@unit)
          return true if @chain.any? { |unit| mixes_in?(unit['source_code'], unit['identifier'], concern, known) }

          concern_sources.any? do |name, text|
            name != concern && mixes_in?(text, name, concern, known) && shown?(name, seen)
          end
        end

        def mixes_in?(source, identifier, concern, known)
          Mixins.calls(source, identifier, :include, :prepend).any? do |name, scopes|
            Mixins.resolve(name, scopes, known) == concern
          end
        end

        # [concern name, decoded source] of each block the owner inlines.
        def concern_sources
          @concern_sources ||= MethodTable.named_blocks(lines_of(@unit)).map { |_, text, name| [name, text] }
        end

        # The superclass chain, nearest first, as far as published units go.
        # @stop names the parent the walk did not read, or is :unrecorded
        # when the last unit names no parent; nil when the chain ends at a
        # framework root. @stop_reason says why the parent was not read.
        def read_chain
          @chain = [@unit]
          @stop = nil
          seen = Set[@unit['identifier']]
          loop do
            name, type = parent_of(@chain.last)
            break @stop = :unrecorded unless name
            break if FRAMEWORK_ROOTS.include?(name)

            @stop_reason = unread_reason(name, seen)
            parent = @stop_reason ? nil : find(name, type)
            @stop_reason ||= parent_reason(name, parent)
            break @stop = name if @stop_reason

            @chain << parent
            seen << name
          end
        end

        def unread_reason(name, seen)
          return "the chain names #{name} twice" if seen.include?(name)

          "Woods reads at most #{MAX_DEPTH} superclasses" if @chain.size >= MAX_DEPTH
        end

        def parent_reason(name, parent)
          return "its parent #{name} is not a published unit" unless parent
          return nil if comparable?(parent)

          "its parent #{name} is published as a #{parent['type']} unit, which does not inline its concerns"
        end

        def comparable?(parent)
          !INLINING_TYPES.include?(@unit['type']) || INLINING_TYPES.include?(parent['type'])
        end

        def find(name, type)
          return nil unless @find_unit

          @find_unit.call(name, type)
        end

        # [parent identifier, its unit type], from the `:inheritance` edge or
        # the unit's `parent_class`.
        def parent_of(unit)
          edge = Array(unit['dependencies']).find { |dep| dep.is_a?(Hash) && dep['via'].to_s == 'inheritance' }
          return [edge['target'], edge['type']] if edge && edge['target']

          metadata = unit['metadata'].is_a?(Hash) ? unit['metadata'] : {}
          parent = metadata['parent_class']
          parent.is_a?(String) && !parent.empty? ? [parent.delete_prefix('::'), unit['type']] : nil
        end

        def state_caveats
          answer_level = level
          @unpublished_prepends.each do |prepend_level, unit, names|
            next if prepend_level > answer_level

            names.each do |name|
              @caveats << "#{unit['identifier']} calls `prepend #{name}`, and the index does not publish the " \
                          "methods of #{name}: if it defines #{@reference.name}, Ruby calls that definition first."
            end
          end
          chain_caveat(answer_level)
        end

        # A concern answer from the last unit read, when the chain stops short
        # of a framework root, is in doubt only if the concern may have come
        # through the unread superclass: then that superclass's own definition
        # comes first in Ruby. A concern mixed in at a level Woods read sits
        # before every unread superclass, so it needs no caveat. A chain that
        # ends at a framework root needs none either: a framework class holds
        # no application definition.
        def chain_caveat(answer_level)
          answered = chosen ? [chosen] : ambiguous
          return unless @stop && answer_level == @chain.size - 1 && answered.all? { |found| found.origin == :concern }

          unshown = answered.map(&:concern).uniq.reject { |concern| shown?(concern) }
          return if unshown.empty?

          @caveats << "No unit Woods read (#{@chain.map { |unit| unit['identifier'] }.join(', ')}) includes " \
                      "#{unshown.join(', ')} in its own body, so #{@unit['identifier']} includes " \
                      "#{unshown.size == 1 ? 'it' : 'them'} through a superclass Woods did not read " \
                      "(#{stop_why}); that superclass's own definition of #{@reference.name} could come first."
        end

        def stop_why
          @stop == :unrecorded ? "#{@chain.last['identifier']} records no parent class" : @stop_reason
        end

        # `include` and `prepend` calls written directly in a class or module
        # body, read by a Prism walk, and the lexical resolution of the
        # constants they name.
        module Mixins
          module_function

          # @param source [String, nil] published source, or a concern's
          #   decoded block
          # @param identifier [String] the class or module whose body is read
          # @param kinds [Array<Symbol>] the call names to read
          # @return [Array<Array(String, Array<String>)>] each mixed-in
          #   constant as written, with the lexical scopes it is written in
          #   (innermost first), nearest first in Ruby's order: the last call
          #   first, and the arguments of one call in their written order
          def calls(source, identifier, *kinds)
            return [] unless source.is_a?(String)

            parsed = Woods::ParseCache.parse(source)
            return [] if parsed.errors.any?

            body, scopes = body_of(parsed.value.statements, [], identifier)
            found = ConcernClassMethods.statements(body).select { |node| mixin_call?(node, kinds) }
            found.reverse.flat_map do |call|
              call.arguments.arguments.filter_map do |argument|
                name = MethodTable::Names.constant_name(argument)
                [name, scopes] if name
              end
            end
          end

          # The concern a written constant names, the way Ruby resolves it:
          # each enclosing lexical scope, innermost first, then the top level.
          # A name that resolves to no known concern, or that the scopes leave
          # open, is not resolved.
          #
          # @param name [String] the constant as written (`Foo`, `A::Foo`, `::Foo`)
          # @param scopes [Array<String>] qualified lexical scopes, innermost first
          # @param known [Array<String>] full names of the inlined concerns
          # @return [String, nil]
          def resolve(name, scopes, known)
            return (known.include?(name.delete_prefix('::')) ? name.delete_prefix('::') : nil) if name.start_with?('::')

            (scopes.map { |scope| "#{scope}::#{name}" } + [name]).find { |candidate| known.include?(candidate) }
          end

          def mixin_call?(node, kinds)
            node.is_a?(Prism::CallNode) && kinds.include?(node.name) && node.arguments &&
              (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
          end

          # The body of the class or module named +identifier+, and the
          # qualified names of the lexical scopes around and including it.
          def body_of(node, scopes, identifier)
            ConcernClassMethods.statements(node).each do |statement|
              next unless statement.is_a?(Prism::ModuleNode) || statement.is_a?(Prism::ClassNode)

              inner = MethodTable::Names.qualified(scopes.first, statement.constant_path)
              next unless inner
              return [statement.body, [inner, *scopes]] if inner == identifier

              found = body_of(statement.body, [inner, *scopes], identifier)
              return found if found.first
            end
            [nil, scopes]
          end
        end
      end
    end
  end
end
