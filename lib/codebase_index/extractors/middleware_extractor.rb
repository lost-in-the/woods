# frozen_string_literal: true

module CodebaseIndex
  module Extractors
    # MiddlewareExtractor handles Rack middleware stack extraction via runtime introspection.
    #
    # Reads the middleware stack from `Rails.application.middleware` and produces
    # a single ExtractedUnit representing the full ordered stack. Each middleware
    # entry includes the class name, arguments, and insertion point.
    #
    # @example
    #   extractor = MiddlewareExtractor.new
    #   units = extractor.extract_all
    #   stack = units.find { |u| u.identifier == "MiddlewareStack" }
    #
    class MiddlewareExtractor
      def initialize
        # No directories to scan — this is runtime introspection
      end

      # Extract the middleware stack as a single ExtractedUnit
      #
      # @return [Array<ExtractedUnit>] Array containing one unit for the stack
      def extract_all
        return [] unless middleware_available?

        stack = Rails.application.middleware
        entries = extract_middleware_entries(stack)

        return [] if entries.empty?

        unit = ExtractedUnit.new(
          type: :middleware,
          identifier: 'MiddlewareStack',
          file_path: nil
        )

        unit.namespace = nil
        unit.source_code = build_stack_source(entries)
        unit.metadata = build_stack_metadata(entries)
        unit.dependencies = []

        [unit]
      rescue StandardError => e
        Rails.logger.error("Failed to extract middleware stack: #{e.message}")
        []
      end

      private

      # Check if Rails middleware stack is available.
      #
      # @return [Boolean]
      def middleware_available?
        defined?(Rails) &&
          Rails.respond_to?(:application) &&
          Rails.application.respond_to?(:middleware)
      end

      # Extract individual middleware entries from the stack.
      #
      # @param stack [ActionDispatch::MiddlewareStack] The middleware stack
      # @return [Array<Hash>] List of middleware entry hashes
      def extract_middleware_entries(stack)
        entries = []
        position = 0

        stack.each do |middleware|
          entry = extract_single_middleware(middleware, position)
          entries << entry if entry
          position += 1
        end

        entries
      end

      # Extract info from a single middleware entry.
      #
      # @param middleware [ActionDispatch::MiddlewareStack::Middleware] A middleware entry
      # @param position [Integer] Position in the stack
      # @return [Hash, nil]
      def extract_single_middleware(middleware, position)
        name = if middleware.respond_to?(:name)
                 middleware.name
               elsif middleware.respond_to?(:klass)
                 middleware.klass.to_s
               else
                 middleware.to_s
               end

        args = if middleware.respond_to?(:args)
                 middleware.args.map(&:to_s)
               else
                 []
               end

        { name: name, args: args, position: position }
      rescue StandardError
        nil
      end

      # Build a human-readable source representation of the middleware stack.
      #
      # @param entries [Array<Hash>] Middleware entries
      # @return [String]
      def build_stack_source(entries)
        lines = []
        lines << '# Rack Middleware Stack'
        lines << "# #{entries.size} middleware(s)"
        lines << '#'

        entries.each do |entry|
          args_str = entry[:args].any? ? " (#{entry[:args].join(', ')})" : ''
          lines << "# [#{entry[:position]}] #{entry[:name]}#{args_str}"
        end

        lines.join("\n")
      end

      # Build metadata hash for the middleware stack.
      #
      # @param entries [Array<Hash>] Middleware entries
      # @return [Hash]
      def build_stack_metadata(entries)
        {
          middleware_count: entries.size,
          middleware_list: entries.map { |e| e[:name] },
          middleware_details: entries
        }
      end
    end
  end
end
