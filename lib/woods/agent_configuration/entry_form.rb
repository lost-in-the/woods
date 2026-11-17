# frozen_string_literal: true

require 'json'
require_relative 'error'
require_relative '../mcp/served_identity'

module Woods
  module AgentConfiguration
    # Which {Launcher} form a plan writes. A project configuration is
    # committed and shared, so a new one is relative; user scope names one
    # machine's paths and is always absolute. An existing installation keeps
    # the form it was written in (a receipt from before forms were recorded
    # counts as absolute) until an explicit `--entry-form` changes it.
    module EntryForm
      module_function

      # @param layout [Layout]
      # @param requested [String, nil] `--entry-form`
      # @return [Array(String, String)] the form, and a note when the default
      #   could not be relative
      def choose(layout, requested)
        if layout.scope == 'user'
          if requested == 'relative'
            raise Conflict, 'A relative entry is for project scope only: user scope names this machine\'s paths'
          end

          return ['absolute', nil]
        end
        return [requested, nil] if requested

        recorded = recorded_form(layout)
        if recorded == 'absolute'
          return ['absolute', 'This installation uses the absolute form, which names this machine\'s paths; ' \
                              '`update --entry-form relative` rewrites it path-free']
        end
        return [recorded, nil] if recorded
        return ['relative', nil] if Woods::MCP::ServedIdentity.checkout_root(layout.root)

        ['absolute', "#{layout.root} is not inside a git checkout, so the entry names absolute paths; " \
                     'rerun with --entry-form relative once it is in one']
      end

      # @return [String, nil] the form an existing installation was written in
      def recorded_form(layout)
        return unless File.file?(layout.receipt_path)

        receipt = JSON.parse(File.read(layout.receipt_path))
        intent = receipt.is_a?(Hash) ? receipt['intent'] : nil
        form = intent.is_a?(Hash) ? intent['entry_form'] : nil
        Launcher::FORMS.include?(form) ? form : 'absolute'
      rescue JSON::ParserError, SystemCallError
        nil
      end
    end
  end
end
