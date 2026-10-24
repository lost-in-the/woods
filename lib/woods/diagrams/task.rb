# frozen_string_literal: true

require_relative '../diagrams'
require_relative '../mcp/index_reader'

module Woods
  module Diagrams
    # `woods:diagram[kind,identifier]`: one diagram's Mermaid text on
    # standard output, from the published index under WOODS_OUTPUT (or the
    # configured output directory), without booting Rails. TYPE, DEPTH,
    # DIRECTION, EVENT, TYPES and VIA (comma-separated) are the tool's
    # arguments; each kind reads only its own. A refusal goes to standard
    # error and the task fails.
    class Task
      # @param kind [String, nil]
      # @param identifier [String, nil]
      # @param env [Hash]
      # @param output [IO]
      # @param error [IO]
      def initialize(kind:, identifier:, env: ENV, output: $stdout, error: $stderr)
        @kind = kind
        @identifier = identifier
        @env = env
        @output = output
        @error = error
      end

      # @return [Result] drawn, its text written; else refused, its reason written to the error stream
      # @raise [InvalidRequest, UnitNotFound]
      def run
        raise InvalidRequest, 'Usage: rake "woods:diagram[kind,identifier]"' if blank?(@kind) || blank?(@identifier)

        directory = output_dir
        result = Diagrams.build(MCP::IndexReader.new(directory.to_s), kind: @kind, identifier: @identifier,
                                                                      index_dir: directory, **options)
        if result.drawn?
          @output.puts(result.text)
        else
          print_refusal(result)
        end
        result
      end

      private

      # TYPE and DEPTH, and the kind's own options: an EVENT left in the shell from a
      # lifecycle run does not break a later neighbourhood.
      def options
        own = { direction: @env['DIRECTION'], event: @env['EVENT'], types: list('TYPES'), via: list('VIA') }
        { type: @env['TYPE'], depth: @env['DEPTH'] }.merge(own.slice(*Diagrams.options_for(@kind))).compact
      end

      def list(name)
        value = @env[name]
        value && value.split(',').map(&:strip).reject(&:empty?)
      end

      def print_refusal(result)
        @error.puts("#{result.refusal} (depth #{result.details['depth']}); lower DEPTH or narrow TYPES/VIA.")
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def output_dir
        @env.fetch('WOODS_OUTPUT') do
          require_relative '../../woods'
          Woods.configuration.output_dir
        end
      end
    end
  end
end
