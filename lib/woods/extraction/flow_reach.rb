# frozen_string_literal: true

require 'json'
require 'set'
require_relative '../atomic_file'

module Woods
  module Extraction
    # Which controllers' flow documents step into a set of units, read from
    # the previous generation's flow inverse (`flows/by_unit.json`, #763).
    #
    # An incremental run reassembles a controller's flows when the dependency
    # graph puts the controller near a change ({Extractor#flow_scope_for}).
    # The flow assembler can step into a unit the graph holds no edge to, for
    # example a lib class instantiated inside an action. A change to that unit
    # then leaves the controller's flow carried forward with the old step
    # lines (#945). The inverse records every expanded step, so it names
    # those controllers directly.
    #
    # A generation written before the inverse existed has none; its published
    # flow documents are read instead, the way {FlowPrecomputer} rebuilds the
    # inverse for carried entries.
    class FlowReach
      # @param payload_dir [Pathname] the run's payload, still holding the
      #   previous generation's flow family
      # @param index_entries [Hash{String => String}] the previous
      #   `flows/flow_index.json`: entry point to payload-relative document path
      def initialize(payload_dir:, index_entries:)
        @payload_dir = Pathname.new(payload_dir)
        @index_entries = index_entries
      end

      # Controllers with a flow document that steps into any of +identifiers+.
      #
      # @param identifiers [Enumerable<String>] unit identifiers
      # @return [Set<String>] controller identifiers
      # @raise [Woods::ExtractionError] when the inverse or a document cannot be read
      def controllers_through(identifiers)
        wanted = identifiers.to_set
        return Set.new if wanted.empty?

        inverse.each_with_object(Set.new) do |(identifier, types), controllers|
          next unless wanted.include?(identifier)

          types.each_value do |entry_points|
            entry_points.each do |entry_point|
              controller, action = entry_point.split('#', 2)
              controllers << controller if action
            end
          end
        end
      end

      private

      def inverse
        path = @payload_dir.join('flows', 'by_unit.json')
        return inverse_from_documents unless path.exist?

        data = JSON.parse(AtomicFile.read(path))
        raise ExtractionError, 'previous by_unit.json is not a typed membership map' unless membership_map?(data)

        data
      rescue JSON::ParserError, SystemCallError => e
        raise ExtractionError, "previous flow inverse cannot be read (by_unit.json): #{e.message}"
      end

      def membership_map?(data)
        data.is_a?(Hash) && data.all? do |identifier, types|
          identifier.is_a?(String) && types.is_a?(Hash) &&
            types.all? { |_type, entries| entries.is_a?(Array) && entries.all?(String) }
        end
      end

      def inverse_from_documents
        @index_entries.each_with_object({}) do |(entry_point, relative), inverse|
          Array(flow_document(relative)['steps']).each do |step|
            identifier = expanded_unit(step)
            ((inverse[identifier] ||= {})[step['type'].to_s] ||= []) << entry_point if identifier
          end
        end
      end

      # Every expanded step names its unit; a cycle marker does not expand.
      # An action suffix belongs to the entry point, not to the unit.
      def expanded_unit(step)
        return unless step.is_a?(Hash) && step['type'].to_s != 'cycle' && step['unit'].is_a?(String)

        step['unit'].split('#', 2).first
      end

      def flow_document(relative)
        document = JSON.parse(AtomicFile.read(@payload_dir.join(relative.to_s)))
        raise ExtractionError, "flow document #{relative} is not an object" unless document.is_a?(Hash)

        document
      rescue JSON::ParserError, SystemCallError => e
        raise ExtractionError, "previous flow document cannot be read (#{relative}): #{e.message}"
      end
    end
  end
end
