# frozen_string_literal: true

require 'json'

module Woods
  module SourceInputs
    # Compact wire format: consumers refer to a shared identity table. Internal
    # mutation uses expanded digests so table indices never leak across runs.
    class Manifest
      FILE_NAME = 'source_inputs.json'
      VERSION = 1
      MAX_BYTES = 16 * 1024 * 1024
      class Invalid < StandardError; end

      attr_reader :data

      def self.parse(bytes)
        raise Invalid, 'source_manifest_too_large' if bytes.bytesize > MAX_BYTES

        new(JSON.parse(bytes))
      rescue JSON::ParserError
        raise Invalid, 'invalid_source_manifest'
      end

      def initialize(data)
        @data = data
        validate!
      end

      def expanded
        identities = @data.fetch('identities')
        @data.fetch('scopes').transform_values do |paths|
          paths.transform_values { |index| identities.fetch(index) }
        end
      end

      # Explicit wire fields keep incomplete coverage separate from boot provenance.
      # rubocop:disable Metrics/AbcSize, Metrics/ParameterLists
      def self.build(snapshot:, scopes:, boot_verified:, generation:, errors: [], unverified_scopes: [])
        identities = scopes.values.flat_map(&:values).uniq.sort
        indices = identities.each_with_index.to_h
        new('version' => VERSION, 'generation' => generation, 'root' => snapshot.fetch('root'),
            'key_id' => snapshot.fetch('key_id'), 'rules' => snapshot.fetch('rules'),
            'extra_roots' => snapshot.fetch('extra_roots'), 'boot_verified' => boot_verified,
            'complete' => snapshot.fetch('complete'), 'errors' => (snapshot.fetch('errors') + errors).uniq,
            'unverified_scopes' => unverified_scopes.uniq.sort,
            'identities' => identities, 'metrics' => snapshot.fetch('metrics'),
            'scopes' => scopes.sort.to_h.transform_values do |paths|
              paths.sort.to_h.transform_values { |digest| indices.fetch(digest) }
            end)
      end

      # rubocop:enable Metrics/AbcSize, Metrics/ParameterLists

      private

      def validate!
        raise Invalid, 'unsupported_source_manifest' unless supported_version?
        raise Invalid, 'invalid_source_manifest_header' unless valid_header?

        validate_tables!
        return if @data['extra_roots'].all? { |path| valid_path?(path) }

        raise Invalid, 'invalid_source_roots'
      end

      def validate_tables!
        identities = @data['identities']
        scopes = @data['scopes']
        unless identities.is_a?(Array) && identities.all? { |digest| digest?(digest) } && scopes.is_a?(Hash)
          raise Invalid, 'invalid_source_identity_table'
        end

        scopes.each { |scope, paths| validate_scope!(scope, paths, identities) }
        raise Invalid, 'invalid_source_manifest_coverage' unless valid_coverage?
      end

      def validate_scope!(scope, paths, identities)
        return if scope.is_a?(String) && paths.is_a?(Hash) &&
                  paths.all? { |path, index| valid_entry?(path, index, identities) }

        raise Invalid, 'invalid_source_scope'
      end

      def supported_version?
        @data.is_a?(Hash) && @data['version'] == VERSION &&
          @data['generation'].is_a?(Integer) && @data['generation'].positive?
      end

      def valid_header?
        valid_root? && %w[key_id rules].all? { |key| digest?(@data[key]) } &&
          %w[boot_verified complete].all? { |key| [true, false].include?(@data[key]) }
      end

      def valid_root?
        root = @data['root']
        root.is_a?(String) && root.start_with?('/') && !root.include?("\0")
      end

      def valid_coverage?
        @data['errors'].is_a?(Array) && @data['errors'].all? { |error| valid_error?(error) } &&
          %w[extra_roots unverified_scopes].all? { |key| @data[key].is_a?(Array) && @data[key].all?(String) }
      end

      def valid_error?(error)
        error.is_a?(Hash) && error['reason'].is_a?(String) &&
          (error['path'].nil? || error['path'].is_a?(String))
      end

      def valid_entry?(path, index, identities)
        valid_path?(path) && index.is_a?(Integer) && index >= 0 && index < identities.size
      end

      def valid_path?(path)
        path.is_a?(String) && !path.empty? && !path.start_with?('/') && !path.include?("\0") &&
          path.split('/', -1).none? { |part| ['', '.', '..'].include?(part) }
      end

      def digest?(value)
        value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
      end
    end
  end
end
