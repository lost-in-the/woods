# frozen_string_literal: true

require 'json'
require_relative '../filename_utils'
require_relative '../impact/artifacts'

module Woods
  class PublishedIndex
    # Readers for the precomputed flow family of the pinned generation:
    # `flows/by_unit.json` (W-13, #763) and the documents `flows/flow_index.json`
    # lists. Both are optional artifacts, so absence answers `nil` ("this
    # generation cannot say"), never an empty result. Present but unreadable,
    # malformed or symlinked artifacts raise `IOError`.
    #
    # Reads go through the bounded, no-follow {Woods::Impact::Artifacts} reader
    # that the impact report uses, against this reader's `payload_dir`, so
    # every answer comes from the one generation the reader holds locked.
    module FlowReaders
      # Entry points whose flow documents expanded a step of this typed unit.
      #
      # Membership is bounded flow evidence: a typed step was expanded within
      # the document's assembly depth. An empty list does not prove that no
      # runtime path reaches the unit.
      #
      # @param identifier [String] unit identifier; a controller step such as
      #   `OrdersController#create` belongs to `OrdersController`
      # @param type [String, Symbol] the unit's actual singular type
      # @return [Array<String>, nil] sorted entry-point keys of
      #   `flows/flow_index.json`; nil when the generation publishes no inverse
      # @raise [IOError] when the inverse is unreadable or malformed
      def flow_entry_points(identifier, type:)
        inverse = flow_inverse
        return nil if inverse.nil?

        typed = inverse.fetch(identifier.to_s, {})
        raise IOError, 'Invalid typed flow inverse' unless typed.is_a?(Hash)

        entries = typed.fetch(type.to_s, [])
        unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(String) && !entry.empty? }
          raise IOError, 'Invalid flow inverse membership'
        end

        entries.dup
      end

      # One precomputed flow document, as published (string keys:
      # `entry_point`, `route`, `max_depth`, `steps`, `generated_at`).
      #
      # @param entry_point [String] a `flows/flow_index.json` key, e.g. `OrdersController#create`
      # @return [Hash, nil] nil when the generation has no flow index or the
      #   index does not list the entry point
      # @raise [IOError] when the index or the listed document is unreadable,
      #   malformed, or names another entry point
      def flow_document(entry_point)
        index = flow_index
        return nil unless index&.key?(entry_point.to_s)

        document = flow_artifact(flow_document_path(entry_point.to_s))
        unless document.is_a?(Hash) && document['entry_point'] == entry_point.to_s && document['steps'].is_a?(Array)
          raise IOError, 'Flow document does not match its flow index entry'
        end

        document
      end

      private

      # The whole inverse, parsed once per reader (the generation is pinned).
      #
      # @return [Hash, nil]
      def flow_inverse
        return @flow_inverse if defined?(@flow_inverse)

        inverse = optional_flow_artifact('flows/by_unit.json')
        raise IOError, 'Invalid flow inverse: not a JSON object' unless inverse.nil? || inverse.is_a?(Hash)

        @flow_inverse = inverse
      end

      # The document path FlowPrecomputer writes for an entry point. Derived
      # from the entry point, as the MCP flow loader does, so persisted index
      # values (absolute on pre-#190 indexes) are never followed.
      #
      # @param entry_point [String]
      # @return [String] payload-relative path
      def flow_document_path(entry_point)
        controller, action = entry_point.split('#', 2)
        raise IOError, 'Invalid flow entry point' if controller.to_s.empty? || action.to_s.empty?

        "flows/#{Woods::FilenameUtils.flow_filename(controller, action)}"
      end

      # Entry point to document path, parsed once per reader.
      #
      # @return [Hash, nil]
      def flow_index
        return @flow_index if defined?(@flow_index)

        index = optional_flow_artifact('flows/flow_index.json')
        raise IOError, 'Invalid flow index: not a JSON object' unless index.nil? || index.is_a?(Hash)

        @flow_index = index
      end

      # @param relative [String] payload-relative path
      # @return [Hash, Array, nil] nil when nothing, not even a link, is there
      def optional_flow_artifact(relative)
        path = payload_dir.join(relative)
        return nil unless path.exist? || path.symlink?

        flow_artifact(relative)
      end

      # @param relative [String] payload-relative path
      # @return [Hash, Array]
      # @raise [IOError]
      def flow_artifact(relative)
        Woods::Impact::Artifacts.new(self).read(relative)
      rescue JSON::ParserError, SystemCallError, EncodingError => e
        raise IOError, "Unreadable flow artifact #{relative}: #{e.class}"
      end
    end

    include FlowReaders
  end
end
