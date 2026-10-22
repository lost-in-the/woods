# frozen_string_literal: true

require_relative '../impact/report'
require_relative '../impact/renderers'

module Woods
  module MCP
    # Read-only adapter over retained impact reports and their shared renderers.
    module ChangeImpact
      class << self
        # @return [Hash] bounded schema; selectors use gen:N, SHA or now
        def schema
          strings = { type: 'array', items: { type: 'string', minLength: 1 } }
          identity = { type: 'object', additionalProperties: false, required: %w[identifier type],
                       properties: { identifier: { type: 'string', minLength: 1, maxLength: 10_000 },
                                     type: { type: 'string', minLength: 1, maxLength: 10_000 } } }
          { properties: {
            from: { type: 'string', description: 'Base retained selector: gen:N, SHA or now.' },
            to: { type: 'string', description: 'Head retained selector; default now. Range mode only.' },
            focus: { type: 'array', minItems: 1, items: identity },
            at: { type: 'string', description: 'Focus endpoint selector; default now. Focus mode only.' },
            format: { type: 'string', enum: %w[markdown json mermaid], description: 'Default markdown.' },
            depth: { type: 'integer' }, types: strings, via: strings,
            **Impact::Options::BUDGETS.to_h { |key, _| [key, { type: 'integer' }] }
          } }
        end

        # @param index_dir [String] index root, never a selected payload directory
        # @param arguments [Hash] validated MCP keyword arguments
        # @return [Array(String, Hash)] rendered text and unchanged structured report
        def call(index_dir, **arguments)
          format = arguments.delete(:format) || 'markdown'
          raise ArgumentError, 'Unsupported impact format' unless %w[markdown json mermaid].include?(format)

          report = compute(index_dir, arguments)
          text = format == 'json' ? report.to_json : Impact::Renderers.public_send(format, report)
          [text, report.to_h]
        end

        private

        def compute(index_dir, arguments)
          if arguments.key?(:focus)
            if arguments.key?(:from) || arguments.key?(:to)
              raise ArgumentError, 'Focus and range selectors cannot be mixed'
            end

            identities = JSON.parse(JSON.generate(arguments.delete(:focus)))
            Impact::Report.focus(index_dir, identities: identities, at: arguments.delete(:at) || 'now', **arguments)
          else
            unless arguments[:from] && !arguments.key?(:at)
              raise ArgumentError, 'Range mode requires from and does not accept at'
            end

            Impact::Report.compare(index_dir, from: arguments.delete(:from), to: arguments.delete(:to) || 'now', **arguments)
          end
        end
      end
    end
  end
end
