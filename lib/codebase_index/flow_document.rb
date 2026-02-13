# frozen_string_literal: true

require 'json'

module CodebaseIndex
  # Value object representing an assembled execution flow trace.
  #
  # Contains an ordered list of steps from an entry point through the dependency graph,
  # with each step holding operations extracted from source code in line order.
  #
  # @example Creating and serializing a flow document
  #   doc = FlowDocument.new(
  #     entry_point: "PostsController#create",
  #     route: { verb: "POST", path: "/posts" },
  #     max_depth: 5,
  #     steps: [{ unit: "PostsController#create", type: "controller", operations: [...] }]
  #   )
  #   doc.to_h        # => JSON-serializable Hash
  #   doc.to_markdown  # => human-readable table
  #
  class FlowDocument
    attr_reader :entry_point, :route, :max_depth, :steps, :generated_at

    # @param entry_point [String] The entry point identifier (e.g., "PostsController#create")
    # @param route [Hash, nil] Route info with :verb and :path keys
    # @param max_depth [Integer] Maximum recursion depth used during assembly
    # @param steps [Array<Hash>] Ordered list of step hashes
    # @param generated_at [String, nil] ISO8601 timestamp (defaults to now)
    def initialize(entry_point:, route: nil, max_depth: 5, steps: [], generated_at: nil)
      @entry_point = entry_point
      @route = route
      @max_depth = max_depth
      @steps = steps
      @generated_at = generated_at || Time.now.iso8601
    end

    # Serialize to a JSON-compatible Hash.
    #
    # @return [Hash] Complete flow document data
    def to_h
      {
        entry_point: @entry_point,
        route: @route,
        max_depth: @max_depth,
        generated_at: @generated_at,
        steps: @steps
      }
    end

    # Reconstruct a FlowDocument from a serialized Hash.
    #
    # Handles both symbol and string keys for JSON round-trip compatibility.
    #
    # @param data [Hash] Previously serialized flow document data
    # @return [FlowDocument]
    def self.from_h(data)
      new(
        entry_point: data[:entry_point] || data['entry_point'],
        route: data[:route] || data['route'],
        max_depth: data[:max_depth] || data['max_depth'] || 5,
        steps: data[:steps] || data['steps'] || [],
        generated_at: data[:generated_at] || data['generated_at']
      )
    end

    # Render as human-readable Markdown.
    #
    # Produces a document with a header showing the route and entry point,
    # followed by one section per step with an operations table.
    #
    # @return [String] Markdown-formatted flow document
    def to_markdown
      lines = []
      lines << format_header
      lines << ''

      @steps.each_with_index do |step, idx|
        lines << format_step(step, idx + 1)
        lines << ''
      end

      lines.join("\n")
    end

    private

    # Format the document header with route and entry point info.
    def format_header
      if @route
        verb = @route[:verb] || @route['verb'] || '?'
        path = @route[:path] || @route['path'] || '?'
        "## #{verb} #{path} → #{@entry_point}"
      else
        "## #{@entry_point}"
      end
    end

    # Format a single step as a Markdown section with operations table.
    def format_step(step, number)
      unit = step[:unit] || step['unit']
      file_path = step[:file_path] || step['file_path']
      operations = step[:operations] || step['operations'] || []

      lines = []
      lines << "### #{number}. #{unit}"
      lines << "_#{file_path}_" if file_path
      lines << ''

      if operations.any?
        lines << '| # | Operation | Target | Line |'
        lines << '|---|-----------|--------|------|'
        format_operations(operations, lines)
      else
        lines << '_No significant operations_'
      end

      lines.join("\n")
    end

    # Format operations into table rows, handling nesting for transactions and conditionals.
    def format_operations(operations, lines, prefix: '')
      operations.each_with_index do |op, idx|
        num = "#{prefix}#{idx + 1}"
        op_type = op[:type] || op['type']
        op_type_str = op_type.to_s

        case op_type_str
        when 'transaction'
          receiver = op[:receiver] || op['receiver']
          line = op[:line] || op['line']
          lines << "| #{num} | transaction | #{receiver}.transaction | #{line} |"
          nested = op[:nested] || op['nested'] || []
          format_operations(nested, lines, prefix: "#{num}.")
        when 'conditional'
          condition = op[:condition] || op['condition']
          kind = op[:kind] || op['kind'] || 'if'
          line = op[:line] || op['line']
          lines << "| #{num} | #{kind} #{condition} | | #{line} |"
          then_ops = op[:then_ops] || op['then_ops'] || []
          else_ops = op[:else_ops] || op['else_ops'] || []
          format_operations(then_ops, lines, prefix: "#{num}a.")
          format_operations(else_ops, lines, prefix: "#{num}b.")
        when 'response'
          status = op[:status_code] || op['status_code']
          method = op[:render_method] || op['render_method']
          line = op[:line] || op['line']
          status_text = status ? "#{status}" : '?'
          lines << "| #{num} | response | #{status_text} (via #{method}) | #{line} |"
        when 'async'
          target = op[:target] || op['target']
          method = op[:method] || op['method']
          args = op[:args_hint] || op['args_hint']
          line = op[:line] || op['line']
          args_text = args&.any? ? "(#{args.join(', ')})" : ''
          lines << "| #{num} | async | #{target}.#{method}#{args_text} | #{line} |"
        when 'cycle'
          target = op[:target] || op['target']
          line = op[:line] || op['line']
          lines << "| #{num} | cycle | #{target} (revisit) | #{line} |"
        when 'dynamic_dispatch'
          target = op[:target] || op['target']
          method = op[:method] || op['method']
          line = op[:line] || op['line']
          lines << "| #{num} | dynamic_dispatch | #{target}.#{method} | #{line} |"
        else
          target = op[:target] || op['target']
          method = op[:method] || op['method']
          line = op[:line] || op['line']
          target_text = [target, method].compact.join('.')
          lines << "| #{num} | #{op_type_str} | #{target_text} | #{line} |"
        end
      end
    end
  end
end
