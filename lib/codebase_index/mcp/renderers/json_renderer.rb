# frozen_string_literal: true

module CodebaseIndex
  module MCP
    module Renderers
      # Passthrough renderer that returns JSON.pretty_generate output.
      # Preserves backward-compatible behavior.
      class JsonRenderer < ToolResponseRenderer
        # @param data [Object] Any JSON-serializable data
        # @return [String] Pretty-printed JSON
        def render_default(data)
          JSON.pretty_generate(data)
        end
      end
    end
  end
end
