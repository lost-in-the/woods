# frozen_string_literal: true

module Woods
  module Console
    # Canonical console-tool protocol contract shared by {StubBridge}
    # (the JSON-lines scaffold) and {EmbeddedExecutor} (the in-process
    # executor that ships today). The eventual real bridge-process
    # implementation (Option D — see `docs/design/CONSOLE_SERVER.md`)
    # will also reference this module so every executor that speaks the
    # protocol agrees on the tool vocabulary.
    #
    # Three constants live here:
    #
    # - {SUPPORTED_TOOLS} — the canonical Tier 1 tool list.
    # - {TIER1_TOOLS}     — alias, kept as a distinct name for call
    #   sites that reason about tier semantics rather than the whole
    #   supported set.
    # - {TOOL_HANDLERS}   — tool → `handle_<tool>` method-symbol map.
    #
    # Previously these lived on {StubBridge} and {EmbeddedExecutor}
    # borrowed them with `TIER1_TOOLS = StubBridge::TIER1_TOOLS`, which
    # reads as "the real executor borrows constants from the stub" —
    # backwards. Extracting the protocol here lets the real executor
    # (and a future non-stub `Bridge` class) claim the contract without
    # importing the scaffold.
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
