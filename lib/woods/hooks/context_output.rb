# frozen_string_literal: true

require 'json'

module Woods
  module Hooks
    # Bounds the complete client JSON envelope, preserving whole evidence rows.
    class ContextOutput
      MAX_BYTES = 2048
      UNAVAILABLE = 'Woods context unavailable or incomplete; inspect woods_status ' \
                    'and verify with search/lookup/dependents.'

      def initialize(kind)
        @kind = kind
      end

      def context(header, rows = [], partial: false)
        selected = []
        rows.each do |row|
          if envelope(([header] + selected + [row, footer(true)]).join("\n")).bytesize > MAX_BYTES
            partial = true
            break
          end
          selected << row
        end
        text = ([header] + selected + [footer(partial)]).join("\n")
        envelope(text).bytesize <= MAX_BYTES ? text : UNAVAILABLE
      end

      def encode(context)
        result = envelope(context)
        result.bytesize <= MAX_BYTES ? result : envelope(UNAVAILABLE)
      end

      private

      def footer(partial)
        "truncated: #{partial ? 'yes' : 'no'}; depth<=2, nodes<=10, edges<=100. " \
          'Verify with dependents explain:true; candidates and test suggestions are not proof.'
      end

      def envelope(context)
        JSON.generate(hookSpecificOutput: { hookEventName: @kind, additionalContext: context })
      end
    end
  end
end
