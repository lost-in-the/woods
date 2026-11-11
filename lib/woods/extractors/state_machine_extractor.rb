# frozen_string_literal: true

require_relative '../source_file'
require_relative '../source_inputs/consumer_errors'
require_relative '../parse_cache'

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'line_neutralizer'
require_relative 'source_nesting'
require_relative 'class_declarations'
require_relative 'transition_callbacks'
require_relative '../source_references/runtime_lookup'

module Woods
  module Extractors
    # StateMachineExtractor scans app/models for state machine DSL definitions.
    #
    # Supports three state machine gems:
    # - AASM: files that include AASM with +aasm do...end+ blocks
    # - Statesman: files that include Statesman::Machine with state/transition calls
    # - state_machines: literal +state_machine+ declarations, with default or named attributes
    #
    # Produces one ExtractedUnit per state machine definition found.
    # A single model file can produce multiple units (e.g., two state_machine blocks).
    #
    # @example
    #   extractor = StateMachineExtractor.new
    #   units = extractor.extract_all
    #   order_sm = units.find { |u| u.identifier == "Order::aasm" }
    #   order_sm.metadata[:states]  # => ["pending", "processing", "completed"]
    #   order_sm.metadata[:gem_detected]  # => "aasm"
    #
    class StateMachineExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner
      include SourceNesting

      MODEL_DIRECTORIES = %w[app/models].freeze

      # Kernel methods that call their block exactly once, before returning,
      # with +self+ unchanged. An iterator's block (+each+, +times+, +map+)
      # runs once per element, which depends on runtime values, so it is not
      # among them.
      RUNS_BLOCK_ONCE = %i[tap then yield_self].freeze

      # Methods that run their block once with their receiver as +self+, so
      # only a receiverless or +self+ call keeps the DSL as +self+.
      EVALUATES_BLOCK_ON_RECEIVER = %i[instance_eval instance_exec].freeze

      # Nodes whose code does not run once, at once, while a DSL block is
      # read. Checked against AASM 6.0.0: an event inside any of them is not
      # registered (+begin; ...; rescue; event(:x); end+ registers only what
      # +begin+, +else+ and +ensure+ hold).
      UNRUN_BODIES = [Prism::RescueNode, Prism::DefinedNode, Prism::WhileNode, Prism::UntilNode,
                      Prism::ForNode].freeze

      # An event declaration that opens a block: the (neutralized) line ends
      # in +do+, optionally with block parameters (`event :pay do |order|`).
      EVENT_BLOCK_OPENER = /\bdo(?:\s*\|[^|]*\|)?\z/

      def initialize
        @directories = MODEL_DIRECTORIES.map { |d| Rails.root.join(d) }.select(&:directory?)
      end

      # Extract all state machine definitions from model files.
      #
      # @return [Array<ExtractedUnit>] List of state machine units
      def extract_all
        find_files_in_directories(@directories).flat_map { |file| extract_model_file(file) }
      end

      # Extract state machine definitions from a single model file.
      #
      # Returns an Array because one model file may contain multiple state machine
      # definitions (e.g., multiple +state_machine+ blocks for different attributes).
      #
      # @param file_path [String] Path to the model file
      # @return [Array<ExtractedUnit>] List of state machine units (empty if none detected)
      def extract_model_file(file_path)
        source = SourceFile.read(file_path)
        class_name = detect_class_name(source, file_path)

        units = []
        units.concat(extract_aasm_units(source, class_name, file_path))
        units.concat(extract_statesman_units(source, class_name, file_path))
        units.concat(extract_state_machines_units(source, class_name, file_path))
        units
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract state machines from #{file_path}: #{e.message}")
        []
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Class Discovery
      # ──────────────────────────────────────────────────────────────────────

      # Detect the fully-qualified class name from source or derive it from
      # the file path.
      #
      # Uses the position-aware nesting scanner (SourceNesting) so a model
      # defined as `module Billing; class Payment` is named
      # +Billing::Payment+, not bare +Payment+ (#174).
      #
      # @param source [String] Ruby source code
      # @param file_path [String] File path
      # @return [String] Fully-qualified class name
      def detect_class_name(source, file_path)
        qualified = governed_class_name(file_path, source) || qualified_first_class_name(source)
        return qualified if qualified

        relative = file_path.sub("#{Rails.root}/", '')
        relative.sub(%r{^app/models/}, '').sub('.rb', '').camelize
      end

      # ──────────────────────────────────────────────────────────────────────
      # AASM
      # ──────────────────────────────────────────────────────────────────────

      # Extract AASM state machine units from source.
      #
      # @param source [String] Ruby source code
      # @param class_name [String] Model class name
      # @param file_path [String] File path
      # @return [Array<ExtractedUnit>]
      def extract_aasm_units(source, class_name, file_path)
        return [] unless source.match?(/include\s+AASM/)

        states = source.scan(/^\s*state\s+:(\w+)/).flatten
        initial_state = parse_initial_state_aasm(source)
        parsed = Woods::ParseCache.parse(source)
        events = if parsed.success?
                   aasm_definitions(parsed.value).flat_map { |definition| parse_events_from_node(definition) }
                 else
                   parse_events_from_source(source, /\Aevent\s+:(\w+)/)
                 end
        callbacks = parse_state_machine_callbacks(source)
        transition_callbacks = TransitionCallbacks.read(parsed.value)

        [build_unit(
          identifier: "#{class_name}::aasm",
          class_name: class_name,
          file_path: file_path,
          source: source,
          gem_detected: 'aasm',
          states: states,
          events: events,
          transitions: events.flat_map { |e| e[:transitions] },
          initial_state: initial_state,
          callbacks: callbacks,
          transition_callbacks: transition_callbacks
        )]
      end

      # Parse initial state from AASM source.
      #
      # Handles both:
      #   state :pending, initial: true
      #   aasm initial: :pending do
      #
      # @param source [String] Ruby source code
      # @return [String, nil]
      def parse_initial_state_aasm(source)
        match = source.match(/state\s+:(\w+)[^#\n]*initial:\s*true/)
        return match[1] if match

        match = source.match(/aasm\b[^#\n]*initial:\s*:(\w+)/)
        match ? match[1] : nil
      end

      # ──────────────────────────────────────────────────────────────────────
      # Statesman
      # ──────────────────────────────────────────────────────────────────────

      # Extract Statesman state machine units from source.
      #
      # @param source [String] Ruby source code
      # @param class_name [String] Model class name
      # @param file_path [String] File path
      # @return [Array<ExtractedUnit>]
      def extract_statesman_units(source, class_name, file_path)
        return [] unless source.match?(/include\s+Statesman::Machine/)

        states = source.scan(/^\s*state\s+:(\w+)/).flatten
        initial_state = source.match(/state\s+:(\w+)[^#\n]*,\s*initial:\s*true/)&.[](1)
        transitions = parse_statesman_transitions(source)
        callbacks = parse_state_machine_callbacks(source)
        transition_callbacks = TransitionCallbacks.read(Woods::ParseCache.parse(source).value)

        [build_unit(
          identifier: "#{class_name}::statesman",
          class_name: class_name,
          file_path: file_path,
          source: source,
          gem_detected: 'statesman',
          states: states,
          events: [],
          transitions: transitions,
          initial_state: initial_state,
          callbacks: callbacks,
          transition_callbacks: transition_callbacks
        )]
      end

      # Parse transitions from Statesman source.
      #
      # @param source [String] Ruby source code
      # @return [Array<Hash>] Transitions with :from, :to, :guard keys
      def parse_statesman_transitions(source)
        source.scan(/transition\s+from:\s*:(\w+)\s*,\s*to:\s*:(\w+)/).map do |from, to|
          { from: from, to: to, guard: nil }
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # state_machines gem
      # ──────────────────────────────────────────────────────────────────────

      # Extract state_machines gem state machine units from source.
      #
      # Handles default/named attributes and parenthesized declarations, with
      # each machine's metadata restricted to its own block.
      #
      # @param source [String] Ruby source code
      # @param class_name [String] Model class name
      # @param file_path [String] File path
      # @return [Array<ExtractedUnit>]
      def extract_state_machines_units(source, class_name, file_path)
        return [] unless source.match?(/\bstate_machine\b/)

        owners = ClassDeclarations.read(source).select { |record| record[:identifier] == class_name }
        declarations = owners.flat_map { |record| state_machine_declarations(record[:node].body) }
        declarations.filter_map do |declaration|
          attr_name = state_machine_attribute(declaration)
          next unless attr_name

          block = declaration.block&.location&.slice.to_s
          states = block.scan(/^\s*state\s+:(\w+)/).flatten
          events = parse_events_from_node(declaration.block)
          initial_state = state_machine_initial_state(declaration)
          callbacks = parse_state_machine_callbacks(block)
          transition_callbacks = TransitionCallbacks.read(declaration.block)

          build_unit(
            identifier: "#{class_name}::state_machine_#{attr_name}",
            class_name: class_name,
            file_path: file_path,
            source: source,
            gem_detected: 'state_machines',
            states: states,
            events: events,
            transitions: events.flat_map { |e| e[:transitions] },
            initial_state: initial_state,
            callbacks: callbacks,
            transition_callbacks: transition_callbacks
          )
        end
      end

      # Read only direct calls in the selected class body. Nested classes,
      # singleton classes and deferred/receiver blocks do not belong to it.
      #
      # @param node [Prism::Node, nil] selected class body or direct statement
      # @return [Array<Prism::CallNode>] state machine declarations in source order
      def state_machine_declarations(node)
        if node.is_a?(Prism::StatementsNode)
          return node.body.flat_map { |statement| state_machine_declarations(statement) }
        end

        if node.is_a?(Prism::CallNode) && node.name == :state_machine &&
           (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
           (node.block.nil? || node.block.is_a?(Prism::BlockNode))
          return [node]
        end

        []
      end

      # The +aasm+ definitions in the parsed model, in source order.
      #
      # Events are read only inside these blocks: an +event+ call in a
      # callback (+after_commit { event(:x) }+), a +define_method+ block or a
      # method body runs later and declares nothing. A definition inside
      # another block, such as a concern's +included do+, still counts, and
      # so does a literal proc forwarded as the block (+aasm(&proc { ... })+).
      #
      # @param node [Prism::Node, nil] parsed source
      # @return [Array<Prism::BlockNode, Prism::LambdaNode>] the definitions' blocks
      def aasm_definitions(node)
        definitions = []
        each_call_outside_methods(node) do |call|
          next false unless call.name == :aasm && (call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode))

          block = literal_block(call)
          next false unless block

          definitions << block
          true
        end
        definitions
      end

      # The block a DSL call reads, when the source states it: a +do+/braces
      # block, or a forwarded +proc { }+, +Proc.new { }+, +lambda { }+ or
      # +-> { }+ literal. Any other forwarded expression (a variable, a method
      # call, +method(:x)+) is not evaluated.
      #
      # AASM 6.0.0 runs the definition's and each event's block with
      # +instance_eval+, which passes the receiver as one argument. A proc
      # ignores it; a lambda raises +ArgumentError+ unless it accepts exactly
      # one positional argument, so only such a lambda declares anything
      # (see {#takes_one_argument?}).
      #
      # @param call [Prism::CallNode]
      # @return [Prism::BlockNode, Prism::LambdaNode, nil]
      def literal_block(call)
        block = call.block
        return block if block.is_a?(Prism::BlockNode)
        return unless block.is_a?(Prism::BlockArgumentNode)

        forwarded = block.expression
        return forwarded if forwarded.is_a?(Prism::LambdaNode) && takes_one_argument?(forwarded.parameters)
        return unless forwarded.is_a?(Prism::CallNode) && forwarded.block.is_a?(Prism::BlockNode)

        body = forwarded.block
        return body if proc_literal?(forwarded)

        body if lambda_literal?(forwarded) && takes_one_argument?(body.parameters)
      end

      # Whether a lambda with these parameters can be called with exactly one
      # positional argument, as +instance_eval+ calls it. Checked against
      # AASM 6.0.0: +->(*)+, +->(dsl)+, +->(dsl, extra = 1)+, +->(dsl, **opts)+,
      # +lambda { |dsl| }+ and +-> { _1 }+ register their events; +-> { }+,
      # +->(a, b)+, +->(dsl, key:)+, +->(**opts)+, +->(&blk)+ and +-> { _2 }+
      # raise. +it+ (Ruby 3.4) is not counted: no supported runtime here
      # confirmed it.
      #
      # @param parameters [Prism::Node, nil] a lambda's or block's parameters
      # @return [Boolean]
      def takes_one_argument?(parameters)
        case parameters
        when Prism::NumberedParametersNode then parameters.maximum == 1
        when Prism::BlockParametersNode then accepts_one_positional?(parameters.parameters)
        else false
        end
      end

      # @param params [Prism::ParametersNode, nil]
      # @return [Boolean]
      def accepts_one_positional?(params)
        return false unless params
        return false if params.keywords.any?(Prism::RequiredKeywordParameterNode)

        required = params.requireds.size + params.posts.size
        return false if required > 1

        required == 1 || params.optionals.any? || params.rest.is_a?(Prism::RestParameterNode)
      end

      # @param node [Prism::CallNode]
      # @return [Boolean] whether +node+ is a bare +lambda+ call
      def lambda_literal?(node)
        node.name == :lambda && node.receiver.nil? && node.arguments.nil?
      end

      # @param node [Prism::Node, nil]
      # @return [Boolean] whether +node+ is +proc { }+ or +Proc.new { }+
      def proc_literal?(node)
        return false unless node.is_a?(Prism::CallNode)
        return node.receiver.nil? && node.arguments.nil? if node.name == :proc

        node.name == :new && node.arguments.nil? && proc_constant?(node.receiver)
      end

      # @param node [Prism::Node, nil]
      # @return [Boolean] whether +node+ is +Proc+ or +::Proc+
      def proc_constant?(node)
        case node
        when Prism::ConstantReadNode then node.name == :Proc
        when Prism::ConstantPathNode then node.parent.nil? && node.name == :Proc
        else false
        end
      end

      # @param declaration [Prism::CallNode] state_machine DSL call
      # @return [String, nil] literal attribute, defaulting to state for options-only calls
      def state_machine_attribute(declaration)
        argument = declaration.arguments&.arguments&.first
        return 'state' if argument.nil? || argument.is_a?(Prism::KeywordHashNode) || argument.is_a?(Prism::HashNode)
        return argument.unescaped if argument.is_a?(Prism::SymbolNode) && argument.unescaped.match?(/\A\w+\z/)

        nil
      end

      # @param declaration [Prism::CallNode] state_machine DSL call
      # @return [String, nil] literal initial state; dynamic initializers are never called
      def state_machine_initial_state(declaration)
        options = declaration.arguments&.arguments&.last
        return unless options.is_a?(Prism::KeywordHashNode) || options.is_a?(Prism::HashNode)

        initial = options.elements.find do |entry|
          entry.is_a?(Prism::AssocNode) && entry.key.is_a?(Prism::SymbolNode) && entry.key.unescaped == 'initial'
        end
        initial.value.unescaped if initial&.value.is_a?(Prism::SymbolNode)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Shared Parsing Helpers
      # ──────────────────────────────────────────────────────────────────────

      # Parse state machine callbacks (before_transition, after_transition, etc.).
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Callback descriptions
      def parse_state_machine_callbacks(source)
        callbacks = []
        source.scan(/(before_transition|after_transition|around_transition|after_failure)\s+(.+?)(?=\n)/) do |cb, args|
          callbacks << "#{cb} #{args.strip}"
        end
        callbacks
      end

      # Parse events from source using a line-by-line depth tracker.
      #
      # This is the fallback for an AASM model whose source does not parse;
      # {#parse_events_from_node} reads every parseable source. Keywords are
      # matched without token context here, so a method named +class+ can
      # still miscount a block.
      #
      # Correctly handles nested blocks (e.g., guard lambdas) within event blocks.
      # Only processes lines after detecting +event :name do+, and closes the event
      # when the matching +end+ is found.
      #
      # Lines are read through {LineNeutralizer.neutralize_lines}, so a +do+ in
      # a comment or a string opens nothing. Inside an event, every opener of
      # an +end+-terminated block counts ({SourceNesting#block_opener?}: do,
      # def, case, begin, loops, statement-position if/unless), and a line
      # that starts with +end+ closes one even with trailing content
      # (+end # pay+, +end)+, +end.tap+; {SourceNesting::END_LINE}). An event
      # still open at the end of the source is kept with the transitions read
      # so far.
      #
      # A blockless declaration (`event :noop`) is complete on its own line and
      # is emitted immediately — the same discipline
      # {FactoryExtractor#match_factory} follows. Leaving it "current" with
      # depth 0 dropped it silently when the next `event` replaced it, and the
      # enclosing block's `end` drove depth negative, after which every later
      # event failed the `depth.zero?` guard (EXTB-17). Depth is clamped at
      # zero so an unbalanced `end` cannot poison the rest of the scan.
      #
      # @param source [String] Source code to parse
      # @param event_pattern [Regexp] Pattern to match event declaration (must capture event name in group 1)
      # @return [Array<Hash>] Events with :name and :transitions keys
      def parse_events_from_source(source, event_pattern)
        events = []
        current_event = nil
        depth = 0

        LineNeutralizer.neutralize_lines(source).each do |line|
          stripped = line.strip
          next if stripped.empty?

          if depth.zero? && (m = stripped.match(event_pattern))
            event = { name: m[1], transitions: [] }
            if stripped.match?(EVENT_BLOCK_OPENER)
              current_event = event
              depth = 1
            else
              events << event
            end
            next
          end

          next unless current_event

          if (t = parse_transition_line(stripped))
            current_event[:transitions] << t
          end

          if stripped.match?(END_LINE)
            depth -= 1
            if depth.zero?
              events << current_event
              current_event = nil
            end
          elsif block_opener?(stripped)
            depth += 1
          end
        end

        events << current_event if current_event
        events
      end

      # Read the events declared under +node+ from the syntax tree.
      #
      # An event is a receiverless +event :name+ call that the definition
      # runs as it is read (see {#each_dsl_call}). Its transitions are the
      # +transition+/+transitions+ calls its own block runs the same way, so
      # block boundaries come from the parser rather than from keywords on a
      # line: a method named +class+ or a +:begin+ symbol opens nothing. A
      # blockless declaration (`event :noop`) is an event with no transitions.
      #
      # @param node [Prism::BlockNode, Prism::LambdaNode, nil] an aasm or state_machine block
      # @return [Array<Hash>] events with :name and :transitions keys, in source order
      def parse_events_from_node(node)
        events = []
        each_dsl_call(node) do |call|
          name = event_name(call)
          events << { name: name, transitions: event_transitions(literal_block(call)) } if name
        end
        events
      end

      # Yield the calls a DSL block runs while it is read, in the order Ruby
      # runs them: the calls in its statements, including those under +if+,
      # +unless+, +case+ and +begin+, and for each call its receiver and its
      # arguments before the call itself (+event(:x) { ... }.tap {}+ and
      # +Array(transitions(...))+ declare at once). A call's own block is
      # entered only when Ruby runs it once, at once (see {#runs_block_at_once?}),
      # and a block forwarded with +&+ never is: the rest hold code the DSL
      # keeps for later, such as a callback (+after_all_events { ... }+, an
      # event's +after { ... }+), so an +event+ or +transitions+ call there
      # declares nothing. A method body, a lambda and a class body run later
      # too.
      #
      # @param node [Prism::BlockNode, Prism::LambdaNode, nil] the DSL block
      # @yieldparam call [Prism::CallNode]
      def each_dsl_call(node, &block)
        node = node.body if node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)
        walk_dsl_calls(node, &block)
      end

      # The walk under {#each_dsl_call}, after the DSL block itself has been
      # opened. Any block or lambda met here is a value, not the DSL body: an
      # assigned lambda, one forwarded to a callback (+after(&-> { })+) or a
      # keyword option (+after: -> { }+) is never called while the definition
      # is read, so its body is not entered. The one exception is a block
      # Ruby runs once, at once (see {#runs_block_at_once?}). A +rescue+
      # clause runs only on an error, +defined?+ never runs its operand, and
      # a loop body runs as often as runtime values say, like an iterator's
      # block, so none of them declares (see {UNRUN_BODIES}).
      #
      # @param node [Prism::Node, nil]
      # @yieldparam call [Prism::CallNode]
      def walk_dsl_calls(node, &block)
        case node
        when Prism::CallNode
          walk_dsl_calls(node.receiver, &block)
          walk_dsl_calls(node.arguments, &block)
          walk_dsl_calls(node.block.expression, &block) if node.block.is_a?(Prism::BlockArgumentNode)
          yield node
          walk_dsl_calls(node.block.body, &block) if runs_block_at_once?(node)
        when Prism::RescueModifierNode then walk_dsl_calls(node.expression, &block)
        when Prism::BlockNode, Prism::LambdaNode, Prism::DefNode, Prism::ClassNode, Prism::ModuleNode,
             Prism::SingletonClassNode, *UNRUN_BODIES
          nil
        when Prism::Node then node.compact_child_nodes.each { |child| walk_dsl_calls(child, &block) }
        end
      end

      # @param call [Prism::CallNode]
      # @return [Boolean] whether Ruby runs +call+'s literal block while the
      #   definition is read, with the DSL still +self+. Checked against
      #   AASM 6.0.0, where an event declared in each such block registers.
      def runs_block_at_once?(call)
        return false unless call.block.is_a?(Prism::BlockNode)
        return true if RUNS_BLOCK_ONCE.include?(call.name)

        EVALUATES_BLOCK_ON_RECEIVER.include?(call.name) && call.arguments.nil? &&
          (call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode))
      end

      # Yield every call under +node+ in source order. A call for which the
      # block returns true is not descended into, and neither is a method
      # body: a +def+ runs later, so an +aasm+ call in one defines nothing.
      #
      # @param node [Prism::Node, nil]
      # @yieldparam call [Prism::CallNode]
      # @yieldreturn [Boolean] true to skip the call's children
      def each_call_outside_methods(node, &block)
        return unless node.is_a?(Prism::Node)
        return if node.is_a?(Prism::DefNode)
        return if node.is_a?(Prism::CallNode) && yield(node)

        node.compact_child_nodes.each { |child| each_call_outside_methods(child, &block) }
      end

      # @param call [Prism::CallNode]
      # @return [String, nil] the event's name when +call+ declares one
      def event_name(call)
        return unless call.name == :event && call.receiver.nil?

        argument = call.arguments&.arguments&.first
        return unless argument.is_a?(Prism::SymbolNode)

        name = argument.unescaped
        name if name.match?(/\A\w+\z/)
      end

      # @param block [Prism::BlockNode, Prism::LambdaNode, nil] an event's block
      # @return [Array<Hash>] the transitions declared inside it
      def event_transitions(block)
        transitions = []
        each_dsl_call(block) do |call|
          next unless transition_call?(call)

          transition = transition_from_call(call)
          transitions << transition if transition
        end
        transitions
      end

      # @param call [Prism::CallNode]
      # @return [Boolean] whether +call+ is +transition+ or +transitions+ on
      #   the event itself: no receiver, or an explicit +self+
      def transition_call?(call)
        %i[transition transitions].include?(call.name) &&
          (call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode))
      end

      # Read a transition from the call's keyword arguments, never from its
      # source text: a comment or a string inside the transition's block is
      # not a guard.
      #
      # Handles +from: :a, to: :b, guard: :method+ (AASM, and state_machines'
      # keyword form) and state_machines' +pending: :active+.
      #
      # @param call [Prism::CallNode]
      # @return [Hash, nil] Transition hash with :from, :to, :guard
      def transition_from_call(call)
        pairs = symbol_pairs(call)
        return if pairs.empty?

        if pairs.key?('from') || pairs.key?('to')
          from = state_symbol(pairs['from'])
          to = state_symbol(pairs['to'])
          return unless from && to

          return { from: from, to: to, guard: guard_symbol(pairs['guard']) }
        end

        from, target = pairs.first
        to = state_symbol(target)
        { from: from, to: to, guard: nil } if from.match?(/\A\w+\z/) && to
      end

      # @param call [Prism::CallNode]
      # @return [Hash{String => Prism::Node}] the call's hash arguments whose
      #   keys are symbols, in source order
      def symbol_pairs(call)
        hash = call.arguments&.arguments&.find { |arg| arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode) }
        return {} unless hash

        hash.elements.each_with_object({}) do |element, pairs|
          next unless element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode)

          pairs[element.key.unescaped] ||= element.value
        end
      end

      # @param node [Prism::Node, nil]
      # @return [String, nil] the state a symbol names
      def state_symbol(node)
        node.unescaped if node.is_a?(Prism::SymbolNode) && node.unescaped.match?(/\A\w+\z/)
      end

      # @param node [Prism::Node, nil]
      # @return [String, nil] the guard method a symbol names
      def guard_symbol(node)
        node.unescaped if node.is_a?(Prism::SymbolNode) && node.unescaped.match?(/\A\w+[?!]?\z/)
      end

      # Parse a single transition line into a structured hash.
      #
      # Handles two styles:
      # - AASM/Statesman: +transitions from: :a, to: :b, guard: :method+
      # - state_machines: +transition pending: :active+
      #
      # @param line [String] Stripped source line
      # @return [Hash, nil] Transition hash with :from, :to, :guard, or nil if not a transition
      def parse_transition_line(line)
        if (m = line.match(/transitions?\s+from:\s*:(\w+)\s*,\s*to:\s*:(\w+)/))
          guard = line.match(/guard:\s*:?(\w+[?!]?)/)&.[](1)
          return { from: m[1], to: m[2], guard: guard }
        end

        if (m = line.match(/\Atransition\s+(\w+):\s*:(\w+)/))
          return { from: m[1], to: m[2], guard: nil }
        end

        nil
      end

      # ──────────────────────────────────────────────────────────────────────
      # Unit Construction
      # ──────────────────────────────────────────────────────────────────────

      # Build an ExtractedUnit from parsed state machine data.
      #
      # @param identifier [String] Unit identifier (e.g., "Order::aasm")
      # @param class_name [String] Model class name
      # @param file_path [String] File path
      # @param source [String] Model source code
      # @param gem_detected [String] Which state machine gem was detected
      # @param states [Array<String>] Detected state names
      # @param events [Array<Hash>] Detected events with transitions
      # @param transitions [Array<Hash>] Flat list of all transitions
      # @param initial_state [String, nil] Initial state name
      # @param callbacks [Array<String>] Detected callbacks, one raw DSL line
      #   each (deprecated: kept for one window beside transition_callbacks)
      # @param transition_callbacks [Array<Hash>] structured callbacks from
      #   {TransitionCallbacks.read}, side effects not yet analysed
      # @return [ExtractedUnit]
      def build_unit(identifier:, class_name:, file_path:, source:, gem_detected:,
                     states:, events:, transitions:, initial_state:, callbacks:, transition_callbacks:)
        unit = ExtractedUnit.new(
          type: :state_machine,
          identifier: identifier,
          file_path: file_path
        )

        unit.namespace = extract_namespace(class_name)
        unit.source_code = "# State machine (#{gem_detected}) for #{class_name}\n#{source}"
        unit.metadata = {
          gem_detected: gem_detected,
          states: states,
          events: events,
          transitions: transitions,
          initial_state: initial_state,
          callbacks: callbacks,
          transition_callbacks: analyze_transition_callbacks(transition_callbacks, class_name, source, file_path),
          model_name: class_name
        }
        unit.dependencies = build_dependencies(class_name, source)
        unit
      end

      # Side effects of each symbol method, analysed as model callbacks are.
      #
      # @param entries [Array<Hash>] from {TransitionCallbacks.read}
      # @param class_name [String] the model
      # @param source [String] the model file
      # @param file_path [String] its path
      # @return [Array<Hash>]
      def analyze_transition_callbacks(entries, class_name, source, file_path)
        return entries if entries.empty?

        code, segments = TransitionCallbacks.analysis_source(source, file_path, Rails.root.to_s)
        analyzer = CallbackAnalyzer.new(source_code: code, column_names: loaded_column_names(class_name),
                                        segments: segments)
        TransitionCallbacks.analyze(entries, analyzer)
      end

      # The columns of an already loaded model, read without autoloading;
      # empty when the class is not loaded or has no table. A schema change
      # re-runs this family (PathDispatcher), so the columns stay current.
      #
      # @param class_name [String]
      # @return [Array<String>]
      def loaded_column_names(class_name)
        model = SourceReferences::RuntimeLookup.new.call("::#{class_name}", allow_private: true)[:value]
        return [] unless model.respond_to?(:column_names) && model.respond_to?(:table_exists?) && model.table_exists?

        Array(model.column_names).map(&:to_s)
      rescue StandardError
        []
      end

      # Build dependencies for a state machine unit.
      #
      # Always includes a reference to the host model. Also scans source for
      # service and job references that may be invoked in callbacks.
      #
      # @param class_name [String] Model class name
      # @param source [String] Ruby source code
      # @return [Array<Hash>]
      def build_dependencies(class_name, source)
        deps = [{ type: :model, target: class_name, via: :state_machine }]
        deps.concat(scan_service_dependencies(source, via: :state_machine_callback))
        deps.concat(scan_job_dependencies(source, via: :state_machine_callback))
        consolidate_dependencies(deps)
      end
    end
  end
end
