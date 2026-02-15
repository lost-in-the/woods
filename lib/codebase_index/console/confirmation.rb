# frozen_string_literal: true

# @see CodebaseIndex
module CodebaseIndex
  class Error < StandardError; end unless defined?(CodebaseIndex::Error)

  module Console
    class ConfirmationDeniedError < CodebaseIndex::Error; end

    # Human-in-the-loop confirmation protocol for Tier 4 tools.
    #
    # Supports three modes:
    # - `:auto_approve` — Always approve (for testing/trusted environments)
    # - `:auto_deny` — Always deny (for locked-down environments)
    # - `:callback` — Delegates to a callable that returns true/false
    #
    # Tracks confirmation history for audit purposes.
    #
    # @example Auto-approve mode
    #   confirmation = Confirmation.new(mode: :auto_approve)
    #   confirmation.request_confirmation(tool: 'eval', description: '1+1', params: {})
    #   # => true
    #
    # @example Callback mode
    #   confirmation = Confirmation.new(mode: :callback, callback: ->(req) { req[:tool] != 'eval' })
    #   confirmation.request_confirmation(tool: 'sql', description: 'SELECT 1', params: {})
    #   # => true
    #
    class Confirmation
      VALID_MODES = %i[auto_approve auto_deny callback].freeze

      # @return [Array<Hash>] History of confirmation requests and outcomes
      attr_reader :history

      # @param mode [Symbol] One of :auto_approve, :auto_deny, :callback
      # @param callback [Proc, nil] Required when mode is :callback
      # @raise [ArgumentError] if mode is invalid or callback is missing for callback mode
      def initialize(mode:, callback: nil)
        unless VALID_MODES.include?(mode)
          raise ArgumentError, "Invalid mode: #{mode}. Must be one of: #{VALID_MODES.join(', ')}"
        end

        raise ArgumentError, 'Callback required for callback mode' if mode == :callback && callback.nil?

        @mode = mode
        @callback = callback
        @history = []
      end

      # Request confirmation for a Tier 4 operation.
      #
      # @param tool [String] Tool name
      # @param description [String] Human-readable description of the action
      # @param params [Hash] Tool parameters
      # @return [true] if confirmed
      # @raise [ConfirmationDeniedError] if denied
      def request_confirmation(tool:, description:, params:) # rubocop:disable Naming/PredicateMethod
        approved = evaluate(tool: tool, description: description, params: params)

        @history << {
          tool: tool,
          description: description,
          params: params,
          approved: approved,
          timestamp: Time.now.utc.iso8601
        }

        raise ConfirmationDeniedError, "Confirmation denied for #{tool}: #{description}" unless approved

        true
      end

      private

      # Evaluate the confirmation based on the current mode.
      #
      # @return [Boolean]
      def evaluate(tool:, description:, params:)
        case @mode
        when :auto_approve
          true
        when :auto_deny
          false
        when :callback
          @callback.call({ tool: tool, description: description, params: params })
        end
      end
    end
  end
end
