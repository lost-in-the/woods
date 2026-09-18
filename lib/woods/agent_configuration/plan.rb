# frozen_string_literal: true

require 'base64'
require 'json'
require_relative 'document'

module Woods
  module AgentConfiguration
    # The serialized plan is the write set. Apply checks its original snapshots
    # and never independently recomputes a newer set of intended edits.
    class Plan
      SCHEMA_VERSION = 1

      attr_reader :data

      def initialize(layout:, operation:, evidence: {})
        @data = { 'schema_version' => SCHEMA_VERSION, 'layout' => layout.identity,
                  'operation' => operation, 'evidence' => evidence, 'changes' => [] }
      end

      def self.load(path)
        object = allocate
        object.instance_variable_set(:@data, Document.new(path).json)
        object
      end

      def add(document, content, description:)
        return if content == document.content

        data.fetch('changes') << { 'path' => document.path, 'before' => document.fingerprint,
                                   'after' => content && Base64.strict_encode64(content),
                                   'mode' => document.mode, 'description' => description }
      end

      def validate!(layout)
        validate_format!(layout)
        validate_paths!(layout)
        data.fetch('changes').each { |change| validate_change!(change) }
        self
      rescue KeyError, TypeError, ArgumentError => e
        raise Conflict, "Invalid plan: #{e.message}"
      end

      def self.after_content(change)
        encoded = change.fetch('after')
        encoded && Base64.strict_decode64(encoded).force_encoding(Encoding::UTF_8)
      end

      def self.after_fingerprint(change)
        content = after_content(change)
        { 'sha256' => content && Digest::SHA256.hexdigest(content), 'mode' => content ? change.fetch('mode') : 0o600,
          'exists' => !content.nil? }
      end

      def summary
        data.slice('operation', 'layout', 'evidence').merge(
          'changes' => data.fetch('changes').map do |change|
            change.slice('path', 'description').merge('action' => change['after'] ? 'write' : 'remove')
          end
        )
      end

      def to_json(*arguments)
        data.to_json(*arguments)
      end

      private

      def validate_format!(layout)
        valid = data.is_a?(Hash) && data['schema_version'] == SCHEMA_VERSION && data['layout'] == layout.identity &&
                %w[setup update remove].include?(data['operation']) && data['changes'].is_a?(Array) &&
                data['changes'].all?(Hash)
        return if valid

        raise Conflict, 'Plan format or selected application/client/scope differs; create a fresh preview'
      end

      def validate_paths!(layout)
        paths = data.fetch('changes').map { |change| change.fetch('path') }
        return if paths.uniq == paths && (paths - layout.allowed_paths).empty?

        raise Conflict, 'Plan contains duplicate or out-of-scope targets'
      end

      def validate_change!(change)
        unless change['before'].is_a?(Hash) && change['mode'].is_a?(Integer) && change['mode'].between?(0, 0o777)
          raise Conflict, 'Invalid file snapshot in plan'
        end

        content = self.class.after_content(change)
        return if content.nil?

        raise Conflict, 'Planned file exceeds the supported size' if content.bytesize > Document::MAX_BYTES
        raise Conflict, 'Planned file must contain valid UTF-8' unless content.valid_encoding?
      end
    end
  end
end
