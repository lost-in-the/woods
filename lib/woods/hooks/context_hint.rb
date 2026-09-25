# frozen_string_literal: true

require 'woods/mcp/index_reader'
require_relative 'context_event'
require_relative 'context_output'
require_relative 'context_impact'

module Woods
  module Hooks
    # A bounded snapshot hint. The outer hook process owns the end-to-end deadline.
    class ContextHint
      MAX_ARTIFACT_BYTES = 16 * 1024 * 1024

      def initialize(event:, output_dir:, root: nil)
        @event = ContextEvent.new(event, root: root)
        @output = File.expand_path(output_dir, @event.root)
        @renderer = ContextOutput.new(@event.kind)
      rescue ArgumentError, KeyError, TypeError, SystemCallError
        @event = nil
      end

      def call
        return nil unless @event&.eligible?

        @reader = MCP::IndexReader.new(@output)
        @reader.with_pinned_generation do
          @generation = @reader.generation_identity
          raise ArgumentError if @reader.payload_dir.to_s == @output

          check_artifacts!
          freshness = source_freshness
          text = if @event.kind == 'SessionStart'
                   orientation(freshness)
                 else
                   ContextImpact.new(@reader, @renderer).call(@event.path, @generation.first, freshness)
                 end
          result(text)
        end
      rescue ArgumentError, KeyError, TypeError, NoMethodError, JSON::ParserError, SystemCallError, IOError
        { context: ContextOutput::UNAVAILABLE, identity: nil, session: nil }
      end

      private

      def check_artifacts!
        %w[manifest.json dependency_graph.json source_inputs.json].each do |name|
          file = @reader.payload_dir.join(name)
          next if name == 'source_inputs.json' && !file.exist?

          raise ArgumentError unless file.file? && file.size <= MAX_ARTIFACT_BYTES
        end
      end

      def source_freshness
        status = SourceInputs::Status.new(output_dir: @output, root: @event.root, payload_dir: @reader.payload_dir,
                                          generation: @reader.loaded_generation).call
        return status.fetch('state') unless status['state'] == 'unavailable'

        evidence = status.fetch('unavailable')
        "unavailable (#{evidence.fetch('reason')}; #{evidence.fetch('size_bytes')} bytes; " \
          "limit #{evidence.fetch('limit_bytes')})"
      end

      def orientation(freshness)
        @renderer.context("Woods index generation #{@generation.first}; source freshness: #{freshness}. " \
                          'Use woods_status, search and typed lookup; dependents explain:true suggests checks.')
      end

      def result(text)
        fingerprint = @event.fingerprint
        identity = if fingerprint && @event.session
                     Digest::SHA256.hexdigest(JSON.generate([@event.root, @event.path, @generation, fingerprint, text]))
                   end
        { context: text, identity: identity, session: @event.session, root: @event.root }
      end
    end
  end
end
