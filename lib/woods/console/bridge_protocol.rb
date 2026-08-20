# frozen_string_literal: true

module Woods
  module Console
    # Canonical Tier 1 vocabulary used by {EmbeddedExecutor}. The historical
    # name remains for compatibility after removal of the JSON-lines bridge.
    #
    # Three constants live here:
    #
    # - {SUPPORTED_TOOLS} — the canonical Tier 1 tool list.
    # - {TIER1_TOOLS}     — alias, kept as a distinct name for call
    #   sites that reason about tier semantics rather than the whole
    #   supported set.
    # - {TOOL_HANDLERS}   — tool → `handle_<tool>` method-symbol map.
    #
    module BridgeProtocol
      SUPPORTED_TOOLS = %w[
        count
        sample
        find
        pluck
        aggregate
        association_count
        schema
        recent
        status
      ].freeze

      TIER1_TOOLS = SUPPORTED_TOOLS

      TOOL_HANDLERS = SUPPORTED_TOOLS.to_h { |t| [t, :"handle_#{t}"] }.freeze
    end
  end
end
