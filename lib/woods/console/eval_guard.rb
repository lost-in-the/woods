# frozen_string_literal: true

require_relative '../ast/parser'

# @see Woods
module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Console
    # Raised when EvalGuard rejects a `console_eval` payload.
    class ForbiddenExpressionError < Woods::Error; end

    # Parse-time refusal layer for `console_eval`.
    #
    # Walks the normalized {Woods::Ast::Parser} tree of the proposed Ruby
    # snippet and refuses any expression that reaches a known credential or
    # reflection escape — so an LLM-generated `Rails.application.credentials
    # .stripe.secret_key` or a reflection escape is rejected before the bridge
    # ever sees it.
    #
    # This is defense in depth, not the only line: the bridge process must
    # re-enforce the same rules at execution time. The gem-side check exists
    # so the LLM sees a fast, visible refusal instead of relying on the host
    # app's bridge configuration.
    #
    # @example
    #   EvalGuard.check!('User.count')                                # => true
    #   EvalGuard.check!('Rails.application.credentials.stripe.key')  # raises
    #
    class EvalGuard # rubocop:disable Metrics/ClassLength
      # Receivers/calls whose presence in the AST is always a refusal.
      # Each entry is matched against the dotted source text of every send
      # node's receiver (and qualified call name) — so a denial of
      # `Rails.application.credentials` catches every chained access through it
      # (e.g. `Rails.application.credentials.dig(:stripe)`).
      DENIED_CALL_CHAINS = %w[
        Rails.application.credentials
        Rails.application.secrets
        Rails::Secrets
        Devise.secret_key
      ].freeze

      # Constants whose bare reference (or use as a receiver) is denied —
      # `ENV`, `ENV['X']`, and `ENV.fetch('X')` all fall under this.
      DENIED_CONSTANTS = %w[ENV].freeze

      # Method names that escape the AST sandbox regardless of receiver.
      DENIED_REFLECTION = %w[
        eval instance_eval class_eval module_eval
        send public_send const_get binding
      ].freeze

      # Receivers + method-name pairs that read credential files from disk.
      # Triggers when the receiver matches AND any literal argument source
      # contains a known credential path fragment. `Pathname.new(...)` is
      # included so `Pathname.new(...).read` chains are caught at construction.
      CREDENTIAL_FILE_READERS = {
        'File' => %w[read binread readlines],
        'IO' => %w[read binread readlines],
        'Pathname' => %w[read binread new]
      }.freeze
      CREDENTIAL_PATH_HINTS = %w[
        master.key credentials.yml.enc credentials/
        secrets.yml secrets.yml.enc
      ].freeze

      class << self
        # @param code [String] Ruby source proposed for `console_eval`.
        # @return [true] if the code passes every denial check.
        # @raise [ForbiddenExpressionError] on any denial or parse failure.
        def check!(code)
          new.check!(code)
        end
      end

      def initialize(parser: Woods::Ast::Parser.new)
        @parser = parser
      end

      # @param code [String]
      # @return [true]
      # @raise [ForbiddenExpressionError]
      def check!(code) # rubocop:disable Naming/PredicateMethod
        raise ForbiddenExpressionError, 'payload is empty' if code.nil? || code.strip.empty?

        tree = parse_or_refuse(code)
        scan_send_nodes(tree)
        scan_const_nodes(tree)
        true
      end

      private

      def parse_or_refuse(code)
        @parser.parse(code)
      rescue Woods::ExtractionError => e
        raise ForbiddenExpressionError, "payload could not be parsed safely: #{e.message}"
      end

      def scan_send_nodes(tree)
        tree.find_all(:send).each do |node|
          refuse_reflection!(node)
          refuse_denied_constant_receiver!(node)
          refuse_denied_constant_in_args!(node)
          refuse_denied_call_chain!(node)
          refuse_credential_file_read!(node)
        end
      end

      def scan_const_nodes(tree)
        tree.find_all(:const).each do |node|
          if DENIED_CONSTANTS.include?(node.method_name.to_s)
            raise ForbiddenExpressionError,
                  "payload references denied constant #{node.method_name}"
          end
        end
      end

      def refuse_reflection!(node)
        return unless DENIED_REFLECTION.include?(node.method_name.to_s)

        raise ForbiddenExpressionError,
              "payload calls reflection method `#{node.method_name}`"
      end

      def refuse_denied_constant_receiver!(node)
        return unless node.receiver && DENIED_CONSTANTS.include?(node.receiver.to_s)

        raise ForbiddenExpressionError,
              "payload references denied constant #{node.receiver}"
      end

      # Catches `puts ENV` — Prism flattens method-call argument nodes into
      # source-text strings, so a bare ENV passed as an argument never appears
      # as its own :const node. Match it as a whole-word token in arg text.
      def refuse_denied_constant_in_args!(node)
        DENIED_CONSTANTS.each do |const|
          pattern = /\b#{Regexp.escape(const)}\b/
          next unless Array(node.arguments).any? { |arg| arg.to_s.match?(pattern) }

          raise ForbiddenExpressionError,
                "payload references denied constant #{const}"
        end
      end

      def refuse_denied_call_chain!(node)
        qualified = qualified_call(node)
        DENIED_CALL_CHAINS.each do |chain|
          next unless qualified.include?(chain)

          raise ForbiddenExpressionError,
                "payload references denied call chain `#{chain}`"
        end
      end

      def refuse_credential_file_read!(node)
        receiver = node.receiver.to_s
        return unless CREDENTIAL_FILE_READERS.key?(receiver)
        return unless CREDENTIAL_FILE_READERS.fetch(receiver).include?(node.method_name.to_s)
        return unless Array(node.arguments).any? { |arg| credential_path?(arg) }

        raise ForbiddenExpressionError,
              "payload reads credential file via `#{receiver}.#{node.method_name}`"
      end

      def qualified_call(node)
        return node.method_name.to_s unless node.receiver

        "#{node.receiver}.#{node.method_name}"
      end

      def credential_path?(arg_text)
        text = arg_text.to_s
        CREDENTIAL_PATH_HINTS.any? { |hint| text.include?(hint) }
      end
    end
  end
end
