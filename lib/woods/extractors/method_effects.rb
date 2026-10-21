# frozen_string_literal: true

require 'set'
require_relative 'callback_analyzer'

module Woods
  module Extractors
    # Attributes side effects to the public methods of one unit's class.
    #
    # Callbacks already say which columns they write and which jobs, mailers
    # and services they reach. A method called explicitly (`ledger.refund!`)
    # said nothing: the unit's edges answered "this file mentions a job
    # somewhere", never "this method enqueues it". This reads each public
    # method body of the unit's class, in the unit's own file, and records:
    #
    #   metadata[:method_effects]["refund!"] = {
    #     jobs_enqueued: [...], mail_sent: [...], services_called: [...],
    #     columns_written: [...], events_published: [...], external_calls: [...],
    #     via_method: { "notify" => { mail_sent: [...] } }
    #   }
    #
    # +via_method+ lists the effects of methods of the same class the method
    # calls, up to {MAX_DEPTH} calls away, each under the name of the method
    # whose body holds them. Class methods are keyed +self.name+.
    #
    # The unit's existing job-enqueue, mailer and service edges gain
    # +through+: the public methods that reach the target, sorted and joined
    # with `", "`. No edge is added or removed.
    #
    # The reading is static and heuristic, like the callback analysis it
    # reuses ({CallbackAnalyzer#method_effects}): calls made through
    # metaprogramming, through another object, or from an included module are
    # not seen.
    class MethodEffects
      # Effect families, in the order they are written.
      FAMILIES = %i[jobs_enqueued mail_sent services_called columns_written events_published external_calls].freeze

      # How many same-class calls away an effect is still attributed.
      MAX_DEPTH = 3

      # Methods recorded per unit when no configuration says otherwise.
      DEFAULT_LIMIT = 50

      # HTTP client constants whose calls count as an external call. The
      # same clients mark a unit-level `:external` dependency.
      HTTP_CLIENTS = %w[Faraday HTTParty Net::HTTP RestClient].freeze

      NOTIFICATION_RECEIVERS = %w[ActiveSupport::Notifications ::ActiveSupport::Notifications].freeze
      NOTIFICATION_METHODS = %w[instrument publish].freeze
      WISPER_METHODS = %w[publish broadcast].freeze
      VISIBILITY_METHODS = %w[private protected public].freeze
      RECEIVER_CHANGING_METHODS = %w[instance_eval instance_exec class_eval class_exec module_eval module_exec].freeze

      # Instance methods Ruby makes private whatever section they are in.
      ALWAYS_PRIVATE = %w[initialize initialize_copy initialize_dup initialize_clone respond_to_missing?].freeze

      # Edge families a +through+ is written on, by dependency type.
      EDGE_FAMILIES = { job: :jobs_enqueued, mailer: :mail_sent, service: :services_called }.freeze

      # One method definition of the unit's class.
      Definition = Struct.new(:key, :node, :visibility, :singleton, keyword_init: true)
      private_constant :Definition

      # Record method effects on +unit+ and name the reaching methods on its
      # edges. A unit whose source does not parse, or whose class has no
      # method with an effect, is left as it was.
      #
      # @param unit [ExtractedUnit] its dependencies must already be set
      # @param source [String, nil] the Ruby source the unit was read from
      # @param class_name [String] the class whose methods are read
      # @param column_names [Array<String>] columns a write is checked against
      # @param skip [Array<String>] methods recorded elsewhere (controller
      #   actions); they still name themselves on edges
      # @param limit [Integer, nil] most methods recorded; nil for no cap
      # @return [ExtractedUnit] +unit+
      def self.apply(unit, source, class_name: unit.identifier, column_names: [], skip: [], limit: default_limit)
        return unit unless source.is_a?(String) && class_name

        new(source, class_name: class_name.to_s, column_names: column_names || []).apply(unit, skip: skip, limit: limit)
        unit
      rescue StandardError, SystemStackError => e
        logger = defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil
        logger&.warn("[Woods] method effects skipped for #{unit.identifier}: #{e.class}: #{e.message}")
        unit
      end

      # @return [Integer, nil] the configured cap, or 50 before Woods is
      #   configured (or when only this file is loaded)
      def self.default_limit
        configuration = Woods.respond_to?(:configuration) ? Woods.configuration : nil
        configuration ? configuration.method_effects_limit : DEFAULT_LIMIT
      end

      # @param source [String]
      # @param class_name [String]
      # @param column_names [Array<String>]
      def initialize(source, class_name:, column_names: [])
        @class_name = class_name.delete_prefix('::')
        @analyzer = CallbackAnalyzer.new(source_code: source, column_names: column_names)
        @wisper = false
        @definitions = {}
        @direct = {}
        collect_definitions
      end

      # @param unit [ExtractedUnit]
      # @param skip [Array<String>]
      # @param limit [Integer, nil]
      # @return [void]
      def apply(unit, skip: [], limit: nil)
        public_keys = @definitions.each_value.select { |definition| definition.visibility == :public }.map(&:key)
        return if public_keys.empty?

        reached = public_keys.to_h { |key| [key, reached_from(key)] }
        record(unit, public_keys - skip.map(&:to_s), reached, limit)
        annotate_edges(unit, public_keys, reached)
      end

      private

      # ── Recording ────────────────────────────────────────────────────

      def record(unit, keys, reached, limit)
        entries = keys.filter_map do |key|
          direct = direct_effects(key)
          via = reached[key]
          next if empty?(direct) && via.empty?

          entry = direct.dup
          entry[:via_method] = via unless via.empty?
          [key, entry]
        end
        return if entries.empty?

        truncated = limit && entries.size > limit
        unit.metadata[:method_effects] = (truncated ? entries.first(limit) : entries).to_h
        unit.metadata[:method_effects_truncated] = true if truncated
      end

      def annotate_edges(unit, keys, reached)
        index = edge_index(keys, reached)
        return if index.empty?

        unit.dependencies = unit.dependencies.map do |dependency|
          methods = index[[edge_family(dependency), dependency[:target].to_s]]
          methods && !dependency.key?(:through) ? dependency.merge(through: methods.sort.join(', ')) : dependency
        end
      end

      # @return [Symbol, nil] the effect family a dependency edge belongs to
      def edge_family(dependency)
        return nil unless dependency.is_a?(Hash)
        return nil if dependency[:via] == :inheritance
        return nil if dependency[:type] == :job && dependency[:via] != :job_enqueue

        EDGE_FAMILIES[dependency[:type]]
      end

      # @return [Hash{Array(Symbol, String) => Array<String>}] the methods
      #   that reach each target, per edge family
      def edge_index(keys, reached)
        keys.each_with_object({}) do |key, index|
          ([direct_effects(key)] + reached[key].values).each do |effects|
            EDGE_FAMILIES.each_value do |family|
              Array(effects[family]).each do |target|
                methods = (index[[family, target]] ||= [])
                methods << key unless methods.include?(key)
              end
            end
          end
        end
      end

      # ── Effects ──────────────────────────────────────────────────────

      # Effects of the same-class methods +key+ calls, breadth first and at
      # most {MAX_DEPTH} calls away. The walk never revisits a method, so a
      # cycle ends where it closes.
      #
      # @return [Hash{String => Hash}] callee name to its non-empty families,
      #   sorted by name
      def reached_from(key)
        seen = Set[key]
        frontier = [key]
        found = {}
        MAX_DEPTH.times do
          frontier = frontier.flat_map { |caller_key| calls_of(caller_key).select { |callee| seen.add?(callee) } }
          break if frontier.empty?

          frontier.each do |callee|
            effects = direct_effects(callee).reject { |_, values| values.empty? }
            found[callee] = effects unless effects.empty?
          end
        end
        found.sort.to_h
      end

      # @return [Hash{Symbol => Array<String>}] every family, empty or not
      def direct_effects(key)
        analysis(key)[:effects]
      end

      # @return [Array<String>] keys of the same-class methods +key+ calls
      def calls_of(key)
        analysis(key)[:calls]
      end

      def analysis(key)
        @direct[key] ||= analyze(@definitions.fetch(key))
      end

      def analyze(definition)
        scanned = @analyzer.method_effects(definition.node) || {}
        sends = method_sends(definition.node)
        {
          effects: {
            jobs_enqueued: scanned[:jobs_enqueued] || [],
            mail_sent: scanned[:mailers_triggered] || [],
            services_called: scanned[:services_called] || [],
            columns_written: scanned[:columns_written] || [],
            events_published: events_published(sends),
            external_calls: external_calls(sends)
          },
          calls: same_class_calls(method_sends(definition.node, same_receiver: true), definition)
        }
      end

      # Nested definitions have their own execution scope. Ordinary blocks
      # keep self; eval/exec blocks on another receiver do not, although the
      # call that obtains that receiver still runs in this method.
      def method_sends(node, same_receiver: false)
        sends = []
        pending = Array(node.children).dup
        while (child = pending.pop)
          next unless child.is_a?(Ast::Node)
          next if %i[def defs class module].include?(child.type)
          next if same_receiver && child.type == :sclass

          sends << child if child.type == :send
          children = Array(child.children)
          if same_receiver && child.type == :block
            call = children.first
            if call&.type == :send && RECEIVER_CHANGING_METHODS.include?(call.method_name) &&
               call.receiver && call.receiver != 'self'
              children = [call]
            end
          end
          pending.concat(children)
        end
        sends
      end

      def empty?(effects)
        effects.each_value.all?(&:empty?)
      end

      def events_published(sends)
        sends.filter_map { |call| notification_event(call) || wisper_event(call) }.uniq.sort
      end

      # @return [String, nil] the literal event name of an
      #   ActiveSupport::Notifications publish
      def notification_event(call)
        return nil unless NOTIFICATION_METHODS.include?(call.method_name)
        return nil unless NOTIFICATION_RECEIVERS.include?(call.receiver)

        string_literal(Array(call.arguments).first)
      end

      # @return [String, nil] the symbol a Wisper publisher broadcasts
      def wisper_event(call)
        return nil unless @wisper && call.receiver.nil? && WISPER_METHODS.include?(call.method_name)

        symbol_literal(Array(call.arguments).first)
      end

      def external_calls(sends)
        sends.filter_map { |call| http_client(call.receiver) }.uniq.sort
      end

      # @param receiver [String, nil] a call's receiver as written
      # @return [String, nil] the HTTP client the receiver starts with
      def http_client(receiver)
        return nil unless receiver

        text = receiver.delete_prefix('::')
        HTTP_CLIENTS.find { |client| text == client || text.start_with?("#{client}.", "#{client}::") }
      end

      def same_class_calls(sends, definition)
        sends.filter_map do |call|
          callee = callee_key(call, definition)
          callee if callee && callee != definition.key && @definitions.key?(callee)
        end.uniq
      end

      # @return [String, nil] the key a receiverless, +self.+ or
      #   +self.class.+ call would resolve to in this class
      def callee_key(call, definition)
        return nil unless call.method_name

        case call.receiver
        when nil, 'self' then definition.singleton ? "self.#{call.method_name}" : call.method_name
        when 'self.class' then definition.singleton ? nil : "self.#{call.method_name}"
        end
      end

      # ── Literals ─────────────────────────────────────────────────────

      # @param text [String, nil] an argument as written
      # @return [String, nil] its value when it is a plain quoted string
      def string_literal(text)
        return nil unless text.is_a?(String) && text.length >= 3

        quote = text[0]
        return nil unless ['"', "'"].include?(quote) && text.end_with?(quote)

        body = text[1..-2]
        body.include?(quote) || body.include?('#{') || body.include?('\\') ? nil : body
      end

      # @param text [String, nil] an argument as written
      # @return [String, nil] the name of a plain `:symbol`
      def symbol_literal(text)
        return nil unless text.is_a?(String) && text.start_with?(':')

        name = text[1..]
        name.empty? || name.match?(/\W/) ? nil : name
      end

      # ── Definitions ──────────────────────────────────────────────────

      def collect_definitions
        root = @analyzer.parsed_root
        return unless root

        containers = []
        find_containers(root, [], containers)
        exact = containers.select { |fqn, _| fqn == @class_name }
        chosen = exact.empty? ? containers.select { |fqn, _| @class_name.end_with?("::#{fqn}") } : exact
        chosen.each { |container| read_body(body_nodes(container.last), singleton: false) }
      end

      # Every class and module in the tree with its lexical name.
      def find_containers(node, namespace, found)
        return unless node.is_a?(Ast::Node)

        inner = namespace
        if %i[class module].include?(node.type) && node.method_name
          name = node.method_name.to_s
          inner = name.start_with?('::') ? [name.delete_prefix('::')] : namespace + [name]
          found << [inner.join('::'), node]
        end
        (node.children || []).each { |child| find_containers(child, inner, found) }
      end

      # Statements of a class, module or singleton-class body, with the
      # wrapper a multi-statement body sits in removed.
      def body_nodes(node)
        (node.children || []).flat_map do |child|
          next [] unless child.is_a?(Ast::Node)

          child.type == :begin ? body_nodes(child) : [child]
        end
      end

      def read_body(statements, singleton:)
        state = { section: :public, module_function: false, singleton: singleton }
        statements.each do |statement|
          case statement.type
          when :def then define(statement, state[:section], state)
          when :defs then define_singleton(statement, :public)
          when :sclass
            read_body(body_nodes(statement), singleton: true) if !singleton && statement.receiver == 'self'
          when :send then read_declaration(statement, state)
          end
        end
      end

      def define(node, visibility, state)
        if state[:singleton] || state[:module_function]
          add("self.#{node.method_name}", node, visibility, true)
        else
          visibility = :private if ALWAYS_PRIVATE.include?(node.method_name)
          add(node.method_name, node, visibility, false)
        end
      end

      def define_singleton(node, visibility)
        add("self.#{node.method_name}", node, visibility, true) if node.receiver == 'self'
      end

      def add(key, node, visibility, singleton)
        @definitions.delete(key)
        @definitions[key] = Definition.new(key: key, node: node, visibility: visibility, singleton: singleton)
      end

      # A receiverless call in a class body: a visibility section or
      # modifier, `private_class_method`, `module_function`, an `include`,
      # or a wrapper around a definition (`memoize def total`).
      def read_declaration(call, state)
        return if call.receiver

        name = call.method_name
        arguments = Array(call.arguments)
        if VISIBILITY_METHODS.include?(name)
          return state[:section] = name.to_sym if arguments.empty?

          modify(call, arguments, name.to_sym, state)
        elsif %w[private_class_method public_class_method].include?(name)
          modify_singleton(call, arguments, name == 'private_class_method' ? :private : :public)
        elsif name == 'module_function' && arguments.empty?
          state[:module_function] = true
        else
          if name == 'include' && arguments.any? { |text| text.delete_prefix('::').start_with?('Wisper') }
            @wisper = true
          end
          define_wrapped(call, state[:section], state)
        end
      end

      def define_wrapped(call, visibility, state)
        wrapped_definitions(call).each do |node|
          node.type == :def ? define(node, visibility, state) : define_singleton(node, :public)
        end
      end

      # `private def name` and `private :name, :other`.
      def modify(call, arguments, visibility, state)
        define_wrapped(call, visibility, state)
        arguments.filter_map { |argument| symbol_literal(argument) }.each do |name|
          key = state[:singleton] ? "self.#{name}" : name
          @definitions[key].visibility = visibility if @definitions.key?(key)
        end
      end

      # Named or inline singleton visibility, including a later
      # `public_class_method :name` that restores a private method.
      def modify_singleton(call, arguments, visibility)
        wrapped_definitions(call).each { |node| define_singleton(node, visibility) if node.type == :defs }
        arguments.filter_map { |argument| symbol_literal(argument) }.each do |name|
          key = "self.#{name}"
          @definitions[key].visibility = visibility if @definitions.key?(key)
        end
      end

      # Definitions passed straight to a call, through any nested wrapper
      # calls (`private memoize def total`).
      def wrapped_definitions(call)
        (call.children || []).flat_map do |child|
          next [] unless child.is_a?(Ast::Node)
          next [child] if %i[def defs].include?(child.type)

          child.type == :send && child.receiver.nil? ? wrapped_definitions(child) : []
        end
      end
    end
  end
end
