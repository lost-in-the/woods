# frozen_string_literal: true

require 'prism'
require 'set'
require_relative '../method_table'
require_relative '../file_lines'
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
      # 2. the unit's own body: its `def`s and the class-body macros that
      #    define the name ({Macros}), the later line first;
      # 3. the concerns inlined at this level: the inlined concerns of the
      #    unit that its parent's unit does not also inline (Ruby skips a
      #    module a superclass already includes).
      #
      # Within one level, the order of the inlined concerns is Ruby's only
      # where the extractor writes them in `included_modules` order (a model,
      # nearest first). A controller's are sorted by name, so two of its
      # concerns that define the name are reported as candidates, not ranked.
      #
      # A call Woods does not know that may define the name is an answer
      # that says it cannot tell, not a step past that level.
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
        # +origin+ is :own, :concern or :prepended, or :macro / :possible_macro
        # for a class-body call that defines the name / may define it.
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
          @overridden = @overridden.reject { |candidate| candidate.origin == :possible_macro }
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

        # The unit's own definitions of the member, latest first: its `def`s
        # and the class-body macros that define the name (:macro) or may
        # (:possible_macro). Both define on the class itself, so the later
        # line is the one Ruby keeps.
        def own_candidates(unit, level)
          name = written_name(unit)
          class_methods = ConcernClassMethods.own_lines(unit['source_code'], name)
          entries = LookupMember.methods_of(unit).select do |entry|
            entry['name'] == @reference.name && !entry['file_unit'] && entry['owner'] == name &&
              @reference.kind?(entry) && !class_methods.include?(entry['line'])
          end
          found = candidates(entries, unit, level, :own, nil) + macro_candidates(unit, level, name)
          found.sort_by { |candidate| -candidate.entry['line'].to_i }
        end

        def macro_candidates(unit, level, name)
          sites = Macros.sites(unit['source_code'], name, @reference)
          return [] if sites.empty?

          metadata = unit['metadata'].is_a?(Hash) ? unit['metadata'] : {}
          locator = FileLines::Locator.new(unit['source_code'], metadata['source_line_map'])
          sites.map do |entry, known|
            Candidate.new(entry: locator.annotate(entry), unit: unit, level: level,
                          origin: known ? :macro : :possible_macro, concern: nil)
          end
        end

        def written_name(unit)
          (@written_names ||= {})[unit['identifier']] ||= WrittenName.call(unit['source_code'], unit['identifier'])
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
        def prepends(unit, inlined)
          written = Prepends.names(unit['source_code'], written_name(unit))
          matched = written.map do |name|
            found = inlined.select { |concern| concern == name || concern.end_with?("::#{name}") }
            found.size == 1 ? found.first : nil
          end
          [matched.compact.uniq, written.reject.with_index { |_, index| matched[index] }]
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

        def chain_caveat(answer_level)
          answered = chosen ? [chosen] : ambiguous
          return unless @stop && answer_level == @chain.size - 1 && answered.all? { |found| found.origin == :concern }

          last = @chain.last['identifier']
          why = if @stop == :unrecorded
                  "#{last} records no parent class"
                else
                  @stop_reason
                end
          @caveats << "The superclass chain of #{@unit['identifier']} was read only up to #{last}: #{why}, so " \
                      'a definition in a superclass Woods did not read could come before this inlined concern.'
        end

        # The name a unit's own class or module declaration has in its
        # published source, which is the name its method table records as
        # the owner. That is the identifier, except for a class an extractor
        # publishes as its own lexical range out of an enclosing class's body
        # (a nested job or PORO): the range opens `class Preview`, so its
        # definitions are owned by `Preview`, not by `Outer::Preview`.
        module WrittenName
          module_function

          # @param source [String, nil] the unit's published source
          # @param identifier [String] the unit's identifier
          # @return [String] the identifier when a declaration in the source
          #   qualifies to it; else the longest top-level declaration that
          #   names the identifier's trailing constants; else the identifier
          def call(source, identifier)
            return identifier unless source.is_a?(String)

            parsed = Woods::ParseCache.parse(source)
            return identifier if parsed.errors.any?

            top = declarations(parsed.value.statements, nil, [])
            return identifier if top.any? { |(_, inner)| inner.include?(identifier) }

            suffixes = top.map(&:first).select { |name| identifier.end_with?("::#{name}") }
            suffixes.max_by(&:length) || identifier
          end

          # [top-level declaration name, every qualified name declared in it]
          def declarations(node, owner, found)
            ConcernClassMethods.statements(node).each do |statement|
              next unless statement.is_a?(Prism::ModuleNode) || statement.is_a?(Prism::ClassNode)

              inner = MethodTable::Names.qualified(owner, statement.constant_path)
              next unless inner

              found << [inner, []] if owner.nil?
              found.last[1] << inner
              declarations(statement.body, inner, found)
            end
            found
          end
        end

        # Receiver-less calls written directly in a unit's own class or module
        # body, outside every `def`, that carry the member's name as a
        # literal positional argument: definitions the method table cannot
        # see, read by a Prism walk. A call Woods knows defines the name
        # (`attr_reader`, `alias_method`, `delegate`, ...) is a definition; any
        # other call but a name reference (visibility, callbacks, validations,
        # `helper_method`) may define it.
        #
        # An instance member is read from the body itself; a class member
        # from `define_singleton_method` in the body, from every call in its
        # `class << self` bodies, and from a call in the body Woods does not
        # know, which may define either side.
        module Macros
          # Calls that define the instance methods they name.
          DEFINERS = %w[attr attr_reader attr_writer attr_accessor alias_method define_method delegate
                        def_delegator def_instance_delegator def_delegators def_instance_delegators].freeze
          # Definers whose method takes the visibility in force where it is
          # called (or of a `private` the call is the argument of).
          SCOPED = %w[attr attr_reader attr_writer attr_accessor define_method].freeze
          SINGLETON_DEFINER = 'define_singleton_method'
          VISIBILITY = %w[private protected public].freeze
          CLASS_VISIBILITY = %w[private_class_method public_class_method].freeze
          # Calls that name a method without defining it.
          REFERENCES = %w[private protected public module_function private_class_method public_class_method
                          private_constant public_constant helper_method validate validates].freeze
          REFERENCE_PREFIX = /\A(?:(?:before|after|around|skip|prepend|append)_|validates_)/

          module_function

          # @param source [String, nil] the unit's published source
          # @param written_name [String] the unit's declaration name in it
          # @param reference [Reference]
          # @return [Array<Array(Hash, Boolean)>] a method table style entry
          #   (`defined_by`, `line`, `end_line`, and `visibility` or
          #   `alias_of` where they are known) for each call, and whether
          #   Woods knows that call defines the name
          def sites(source, written_name, reference)
            return [] unless source.is_a?(String)

            parsed = Woods::ParseCache.parse(source)
            return [] if parsed.errors.any?

            statements = ConcernClassMethods.statements(Prepends.body_of(parsed.value.statements, nil, written_name))
            if reference.separator == '#'
              return marked(scan(statements, reference, :instance), marks(statements, reference.name, VISIBILITY),
                            written_name)
            end

            found = scan(statements, reference, :class_body)
            later = marks(statements, reference.name, CLASS_VISIBILITY)
            statements.each do |node|
              next unless node.is_a?(Prism::SingletonClassNode) && node.expression.is_a?(Prism::SelfNode)

              inner = ConcernClassMethods.statements(node.body)
              found.concat(scan(inner, reference, :singleton_body))
              later.concat(marks(inner, reference.name, VISIBILITY))
            end
            marked(found, later, written_name)
          end

          # A visibility call naming the method after its definition sets
          # its visibility (`private :name`, `private_class_method :name`).
          def marked(found, marks, written_name)
            found.map do |entry, known|
              mark = marks.select { |line, _| line > entry['line'] }.max_by(&:first)
              entry = entry.merge('visibility' => mark.last) if known && mark
              [entry.merge('owner' => written_name), known]
            end
          end

          # [line, visibility] of each call among +statements+ named in
          # +calls+ that names +name+ as a literal argument.
          def marks(statements, name, calls)
            statements.filter_map do |node|
              next unless node.is_a?(Prism::CallNode) && node.receiver.nil? && calls.include?(node.name.to_s)
              next unless names(positional(node)).include?(name)

              [node.location.start_line, node.name.to_s.delete_suffix('_class_method')]
            end
          end

          # The calls among one body's statements, with the default
          # visibility each is written under.
          def scan(statements, reference, side)
            visibility = 'public'
            statements.flat_map do |node|
              if node.is_a?(Prism::CallNode) && node.receiver.nil? && VISIBILITY.include?(node.name.to_s)
                arguments = node.arguments&.arguments.to_a
                visibility = node.name.to_s if arguments.empty?
                next arguments.flat_map { |argument| site(argument, reference, side, node.name.to_s) }
              end
              site(node, reference, side, visibility)
            end
          end

          def site(node, reference, side, visibility)
            if node.is_a?(Prism::AliasMethodNode)
              return [] unless side != :class_body && literals(node.new_name) == [reference.name]

              return [[entry(node, 'alias', reference, alias_of: literals(node.old_name).first), true]]
            end
            return [] unless node.is_a?(Prism::CallNode) && node.receiver.nil?

            macro = node.name.to_s
            verdict = defines(macro, node, reference.name, side)
            return [] unless verdict

            visibility = nil unless verdict == :known && SCOPED.include?(macro)
            alias_of = literals(positional(node)[1]).first if macro == 'alias_method'
            [[entry(node, macro, reference, visibility: visibility, alias_of: alias_of), verdict == :known]]
          end

          # :known when the call defines +name+ on this side, :possible
          # when Woods does not know the call, nil otherwise.
          def defines(macro, node, name, side)
            arguments = positional(node)
            if DEFINERS.include?(macro)
              return nil if side == :class_body

              return defined_names(macro, node, arguments).include?(name) ? :known : delegate_unknown(macro, node, name)
            end
            if macro == SINGLETON_DEFINER
              return side == :class_body && literals(arguments.first) == [name] ? :known : nil
            end
            return nil if REFERENCES.include?(macro) || macro.match?(REFERENCE_PREFIX)

            :possible if arguments.flat_map { |argument| literals(argument) }.include?(name)
          end

          def defined_names(macro, node, arguments)
            case macro
            when 'attr_writer' then names(arguments).map { |name| "#{name}=" }
            when 'attr_accessor' then names(arguments).flat_map { |name| [name, "#{name}="] }
            when 'alias_method', 'define_method' then literals(arguments.first)
            when 'delegate' then delegated(node, arguments)
            when 'def_delegator', 'def_instance_delegator' then literals(arguments[2] || arguments[1])
            when 'def_delegators', 'def_instance_delegators' then names(arguments.drop(1))
            else names(arguments)
            end
          end

          # `delegate :x, to: :y` defines x; with `prefix: true` it defines
          # y_x, and with `prefix: :p` p_x.
          def delegated(node, arguments)
            prefix = delegate_prefix(node)
            return [] if prefix == :unknown

            names(arguments).map { |name| prefix ? "#{prefix}_#{name}" : name }
          end

          # A `delegate` whose prefix is not a literal may define the name.
          def delegate_unknown(macro, node, name)
            return nil unless macro == 'delegate' && delegate_prefix(node) == :unknown

            names(positional(node)).include?(name) ? :possible : nil
          end

          # @return [String, nil, :unknown] the prefix a `delegate` call adds
          def delegate_prefix(node)
            options = keywords(node)
            prefix = options['prefix']
            case prefix
            when nil, Prism::FalseNode, Prism::NilNode then nil
            when Prism::TrueNode
              target = literals(options['to']).first
              target ? target.delete_prefix('@') : :unknown
            else literals(prefix).first || :unknown
            end
          end

          def keywords(node)
            hash = node.arguments&.arguments.to_a.find { |argument| argument.is_a?(Prism::KeywordHashNode) }
            (hash ? hash.elements : []).each_with_object({}) do |element, found|
              next unless element.is_a?(Prism::AssocNode)

              key = literals(element.key).first
              found[key] = element.value if key
            end
          end

          def positional(node)
            node.arguments&.arguments.to_a.reject do |argument|
              argument.is_a?(Prism::KeywordHashNode) || argument.is_a?(Prism::BlockArgumentNode)
            end
          end

          def names(arguments)
            arguments.flat_map { |argument| literals(argument) }
          end

          def literals(node)
            MethodTable::Names.symbol_names(node)
          end

          def entry(node, macro, reference, visibility: nil, alias_of: nil)
            found = { 'name' => reference.name, 'kind' => reference.separator == '#' ? 'instance' : 'singleton',
                      'line' => node.location.start_line, 'end_line' => node.location.end_line,
                      'defined_by' => macro }
            found['visibility'] = visibility if visibility
            found['alias_of'] = alias_of if alias_of
            found
          end
        end

        # `prepend` calls written directly in a unit's own class or module
        # body, read by a Prism walk.
        module Prepends
          module_function

          # @param source [String, nil] the unit's published source
          # @param identifier [String] the unit's identifier
          # @return [Array<String>] the prepended constants as written,
          #   nearest first (Ruby puts the last `prepend` call first, and the
          #   arguments of one call in their written order)
          def names(source, identifier)
            return [] unless source.is_a?(String)

            parsed = Woods::ParseCache.parse(source)
            return [] if parsed.errors.any?

            body = body_of(parsed.value.statements, nil, identifier)
            calls = ConcernClassMethods.statements(body).select { |node| prepend_call?(node) }
            calls.reverse.flat_map do |call|
              call.arguments.arguments.filter_map do |argument|
                MethodTable::Names.constant_name(argument)&.delete_prefix('::')
              end
            end
          end

          def prepend_call?(node)
            node.is_a?(Prism::CallNode) && node.name == :prepend && node.arguments &&
              (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
          end

          def body_of(node, owner, identifier)
            ConcernClassMethods.statements(node).each do |statement|
              next unless statement.is_a?(Prism::ModuleNode) || statement.is_a?(Prism::ClassNode)

              inner = MethodTable::Names.qualified(owner, statement.constant_path)
              next unless inner
              return statement.body if inner == identifier

              found = body_of(statement.body, inner, identifier)
              return found if found
            end
            nil
          end
        end
      end
    end
  end
end
