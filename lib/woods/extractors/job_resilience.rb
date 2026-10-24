# frozen_string_literal: true

require 'prism'
require_relative '../source_file'

module Woods
  module Extractors
    # A job's resilience facts (W-4, #754): what it retries, discards and
    # rescues, and the around_perform callbacks that wrap it.
    #
    # With the job class loaded the facts come from the class itself, so a
    # declaration inherited from ApplicationJob or added by a concern counts,
    # and a comment or a string that mentions `retry_on` does not: Active
    # Job's `rescue_handlers` in the order Rails registered them, each
    # handler classified by the method that created it (`retry_on` and
    # `discard_on` define their handlers in `active_job/exceptions.rb`), with
    # the options it closed over read from its binding, never by calling it;
    # and the job's own `_perform_callbacks`. Framework callbacks (time zone,
    # locale) are left out: only callbacks defined under the application
    # root are published.
    #
    # Without the class (a file read on its own) the same shape comes from
    # Prism over the class body: only real calls count, with literal
    # arguments as written.
    #
    # Every key is always present; a job that declares nothing publishes
    # empty arrays (the "job without retry" fact).
    module JobResilience
      # The file Active Job defines `retry_on` and `discard_on` handlers in.
      EXCEPTIONS_FILE = %r{/active_job/exceptions\.rb\z}

      # Locals a `retry_on` handler closes over, published when set.
      RETRY_OPTIONS = %i[wait attempts queue priority jitter].freeze

      # Class-body calls the static reader understands.
      DECLARATIONS = %w[retry_on discard_on rescue_from].freeze
      JOB_CALLBACKS = %w[before_enqueue after_enqueue around_enqueue before_perform after_perform around_perform].freeze

      module_function

      # @param job_class [Class] an Active Job class
      # @param root [String, Pathname, nil] the application root; callbacks
      #   defined outside it are framework callbacks
      # @return [Hash] retry_on, discard_on, rescue_from, around_perform and
      #   rescue_handlers, with resilience_source 'runtime'
      def runtime(job_class, root:)
        handlers = runtime_handlers(job_class)
        facts(handlers, runtime_around(job_class, root.to_s), 'runtime')
      end

      # @param source [String] the job file
      # @param class_name [String] the job's name
      # @return [Hash] the same shape, with resilience_source 'static'
      def static(source, class_name)
        handlers = []
        around = []
        class_body_calls(source.to_s).each do |call|
          name = call.name.to_s
          if DECLARATIONS.include?(name)
            handlers << static_handler(call, name, class_name)
          elsif name == 'around_perform'
            around << static_callback(call, class_name)
          end
        end
        facts(handlers, around, 'static')
      end

      # Job callbacks declared in the class body, in order: the `callbacks`
      # metadata, read from calls rather than text so a comment is not one.
      #
      # @param source [String]
      # @return [Array<Hash>] type and method (nil for a block)
      def static_callbacks(source)
        class_body_calls(source.to_s).filter_map do |call|
          name = call.name.to_s
          next unless JOB_CALLBACKS.include?(name)

          symbol = Array(call.arguments&.arguments).find { |node| node.is_a?(Prism::SymbolNode) }
          { type: name, method: symbol&.unescaped }
        end
      end

      # @param handlers [Array<Hash>] rescue handlers
      # @param around [Array<Hash>] around_perform callbacks
      # @param source [String] 'runtime' or 'static'
      # @return [Hash] the published shape
      def facts(handlers, around, source)
        {
          retry_on: handlers.select { |h| h[:kind] == 'retry_on' }.flat_map { |h| h[:exceptions] },
          discard_on: handlers.select { |h| h[:kind] == 'discard_on' }.flat_map { |h| h[:exceptions] },
          rescue_from: handlers.select { |h| h[:kind] == 'rescue_from' },
          around_perform: around,
          rescue_handlers: handlers,
          resilience_source: source
        }
      end

      # ── runtime ──────────────────────────────────────────────────────────

      # One declaration per handler: `retry_on A, B` registers both
      # exceptions against the same handler, so consecutive entries sharing
      # a handler are one declaration.
      def runtime_handlers(job_class)
        return [] unless job_class.respond_to?(:rescue_handlers)

        groups = []
        Array(job_class.rescue_handlers).each do |exception, handler|
          if groups.last && groups.last[:handler].equal?(handler)
            groups.last[:exceptions] << exception.to_s
          else
            groups << { handler: handler, exceptions: [exception.to_s] }
          end
        end
        groups.map { |group| runtime_handler(job_class, group[:handler], group[:exceptions]) }
      rescue StandardError
        []
      end

      def runtime_handler(job_class, handler, exceptions)
        kind = handler_kind(handler)
        entry = { kind: kind, exceptions: exceptions }
        case kind
        when 'retry_on' then entry.merge!(retry_options(handler))
        when 'discard_on' then entry[:block] = closure_block?(handler)
        else
          handler.is_a?(Proc) ? entry[:block] = true : entry[:with] = handler.to_s
        end
        entry[:declared_in] = handler_owner(job_class, handler)
        entry
      end

      # @return [String] retry_on, discard_on or rescue_from
      def handler_kind(handler)
        return 'rescue_from' unless handler.is_a?(Proc)

        file, line = handler.source_location
        return 'rescue_from' unless file.to_s.match?(EXCEPTIONS_FILE)

        enclosing_method(file, line) || 'rescue_from'
      end

      # The `def retry_on` or `def discard_on` a handler's line sits in.
      def enclosing_method(file, line)
        @enclosing ||= {}
        lines = @enclosing[file] ||= SourceFile.readlines(file)
        lines.first(line.to_i).reverse_each do |text|
          name = text[/^\s*def\s+(retry_on|discard_on)\b/, 1]
          return name if name
          return nil if text.match?(/^\s*def\s/)
        end
        nil
      rescue StandardError
        nil
      end

      def retry_options(handler)
        options = RETRY_OPTIONS.each_with_object({}) do |local, values|
          next unless handler.binding.local_variable_defined?(local)

          value = label(handler.binding.local_variable_get(local))
          values[local] = value unless value.nil?
        end
        options.merge(block: closure_block?(handler))
      rescue StandardError
        {}
      end

      # `retry_on ... do |job, error| end` keeps the block in a local of
      # the same name.
      def closure_block?(handler)
        handler.binding.local_variable_defined?(:block) && !handler.binding.local_variable_get(:block).nil?
      rescue StandardError
        false
      end

      # The highest class in the chain that already had this handler.
      def handler_owner(job_class, handler)
        owner = job_class
        klass = job_class.superclass
        while klass.respond_to?(:rescue_handlers) && Array(klass.rescue_handlers).any? { |_, h| h.equal?(handler) }
          owner = klass
          klass = klass.superclass
        end
        owner.name
      end

      def runtime_around(job_class, root)
        return [] unless job_class.respond_to?(:_perform_callbacks)

        job_class._perform_callbacks.filter_map do |callback|
          next unless callback.kind == :around

          filter = callback.filter
          next unless application_callback?(job_class, filter, root)

          entry = filter.is_a?(Symbol) ? { method: filter.to_s, block: false } : { method: nil, block: true }
          entry.merge(declared_in: callback_owner(job_class, callback))
        end
      rescue StandardError
        []
      end

      def application_callback?(job_class, filter, root)
        location = case filter
                   when Symbol, String then job_class.instance_method(filter).source_location
                   when Proc then filter.source_location
                   end
        file = location&.first.to_s
        !root.empty? && file.start_with?(File.join(root, ''))
      rescue NameError
        false
      end

      def callback_owner(job_class, callback)
        owner = job_class
        klass = job_class.superclass
        while klass.respond_to?(:_perform_callbacks) && klass._perform_callbacks.any? { |c| c.equal?(callback) }
          owner = klass
          klass = klass.superclass
        end
        owner.name
      end

      # @param value [Object] a captured option
      # @return [Object, nil] JSON-safe: numbers and booleans as they are,
      #   durations and symbols as words, callables as their kind; nil for
      #   anything else
      def label(value)
        case value
        when Integer, Float, true, false then value
        when Symbol then value.to_s
        when Proc then value.lambda? ? 'lambda' : 'Proc'
        else
          duration?(value) ? value.inspect : nil
        end
      end

      # A default Rails marks with a bare sentinel object (`jitter`) is not
      # a declared option, and has no stable spelling, so it is left out.
      def duration?(value)
        defined?(ActiveSupport::Duration) && value.is_a?(ActiveSupport::Duration)
      end

      # ── static ───────────────────────────────────────────────────────────

      # Calls that are direct statements of a class body, receiverless.
      def class_body_calls(source)
        result = Prism.parse(source)
        calls = []
        visit = lambda do |node|
          next unless node

          if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
            Array(node.body&.body).each do |statement|
              calls << statement if statement.is_a?(Prism::CallNode) && statement.receiver.nil?
              visit.call(statement) if statement.is_a?(Prism::ClassNode) || statement.is_a?(Prism::ModuleNode)
            end
          else
            node.compact_child_nodes.each { |child| visit.call(child) }
          end
        end
        visit.call(result.value)
        calls
      rescue StandardError
        []
      end

      def static_handler(call, kind, class_name)
        arguments = Array(call.arguments&.arguments)
        exceptions = arguments.filter_map { |node| constant(node) }
        options = keyword_options(arguments)
        entry = { kind: kind, exceptions: exceptions }
        case kind
        when 'retry_on'
          RETRY_OPTIONS.each { |key| entry[key] = options[key.to_s] if options.key?(key.to_s) }
          entry[:block] = !call.block.nil?
        when 'discard_on' then entry[:block] = !call.block.nil?
        else
          options.key?('with') ? entry[:with] = options['with'].to_s : entry[:block] = !call.block.nil?
        end
        entry[:declared_in] = class_name
        entry
      end

      def static_callback(call, class_name)
        symbol = Array(call.arguments&.arguments).find { |node| node.is_a?(Prism::SymbolNode) }
        symbol ? { method: symbol.unescaped, block: false, declared_in: class_name } : { method: nil, block: true, declared_in: class_name }
      end

      def constant(node)
        node.slice.delete_prefix('::') if node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
      end

      def keyword_options(arguments)
        hash = arguments.find { |node| node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::HashNode) }
        return {} unless hash

        hash.elements.each_with_object({}) do |assoc, options|
          next unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode)

          options[assoc.key.unescaped] = static_value(assoc.value)
        end
      end

      def static_value(node)
        case node
        when Prism::IntegerNode then node.value
        when Prism::SymbolNode then node.unescaped
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        else node.slice
        end
      end
    end
  end
end
