# frozen_string_literal: true

require 'json'
require 'digest'

module Woods
  module SourceInputs
    # Compact wire format: consumers refer to a shared identity table. Internal
    # mutation uses expanded digests so table indices never leak across runs.
    class Manifest # rubocop:disable Metrics/ClassLength -- compact wire validation and bounded serialization
      FILE_NAME = 'source_inputs.json'
      VERSION = 1
      MAX_BYTES = 16 * 1024 * 1024
      UNKNOWN_BASELINES = %w[invalid_source_baseline missing_or_incompatible_source_baseline
                             incomplete_source_baseline].freeze
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

      # Older version-1 writers encoded missing comparison evidence only as
      # errors. Never interpret their empty ledger as proof of an empty tree.
      def comparison_complete?
        @data['complete'] && @data.fetch('comparison_complete', true) &&
          @data.fetch('errors').none? { |error| UNKNOWN_BASELINES.include?(error['reason']) }
      end

      # Explicit wire fields keep incomplete coverage separate from boot provenance.
      # rubocop:disable Metrics/AbcSize, Metrics/ParameterLists
      def self.build(snapshot:, scopes:, boot_verified:, generation:, errors: [], unverified_scopes: [],
                     comparison_complete: true, unavailable: nil)
        identities = scopes.values.flat_map(&:values).uniq.sort
        indices = identities.each_with_index.to_h
        new('version' => VERSION, 'generation' => generation, 'root' => snapshot.fetch('root'),
            'captured_at' => snapshot['captured_at'],
            'key_id' => snapshot.fetch('key_id'), 'rules' => snapshot.fetch('rules'),
            'extra_roots' => snapshot.fetch('extra_roots'), 'boot_verified' => boot_verified,
            'complete' => snapshot.fetch('complete'), 'errors' => (snapshot.fetch('errors') + errors).uniq,
            'comparison_complete' => comparison_complete,
            'unverified_scopes' => unverified_scopes.uniq.sort,
            'identities' => identities, 'metrics' => snapshot.fetch('metrics'),
            'scopes' => scopes.sort.to_h.transform_values do |paths|
              paths.sort.to_h.transform_values { |digest| indices.fetch(digest) }
            end).tap { |manifest| manifest.bound_publication!(snapshot: snapshot, unavailable: unavailable) }
      end

      # rubocop:enable Metrics/AbcSize, Metrics/ParameterLists

      # Compact watch boundary only: this never certifies runtime freshness.
      def self.capture_digest(files)
        Digest::SHA256.hexdigest(JSON.generate(files.sort.to_h))
      end

      def self.valid_unavailable_evidence?(value)
        value.is_a?(Hash) && value['reason'] == 'source_manifest_too_large' &&
          value.values_at('size_bytes', 'limit_bytes').all?(Integer) &&
          value['limit_bytes'].positive? && value['size_bytes'] > value['limit_bytes']
      end

      def unavailable?
        @data['state'] == 'unavailable'
      end

      # Bind only an already validated, generation-local reference cache. This
      # preserves its consumed-source proof without publishing the large ledger.
      def bind_reference_cache!(cache)
        @data['reference_cache_sha256'] = Digest::SHA256.hexdigest(JSON.generate(cache)) if unavailable? && cache
      end

      # Source evidence is advisory. Its size limit must not withhold a valid
      # code index. Keep errors so final publication still refuses unstable input.
      def bound_publication!(snapshot:, unavailable: nil)
        size = JSON.pretty_generate(@data).bytesize
        return unless unavailable || size > MAX_BYTES

        diagnostic = unavailable || { 'reason' => 'source_manifest_too_large',
                                      'size_bytes' => size, 'limit_bytes' => MAX_BYTES }
        @data['capture_sha256'] = self.class.capture_digest(snapshot.fetch('files')) if snapshot['complete']
        @data.merge!('state' => 'unavailable', 'unavailable' => diagnostic,
                     'complete' => false, 'comparison_complete' => false,
                     'identities' => [], 'scopes' => {}, 'metrics' => {})
        warn "[woods] source freshness unavailable: #{diagnostic['reason']}; " \
             "#{diagnostic['size_bytes']} bytes exceeds limit #{diagnostic['limit_bytes']}. " \
             'Publishing the code index without freshness comparison evidence; ' \
             'another full extraction will not reduce this size.'
      end

      private

      def validate!
        raise Invalid, 'unsupported_source_manifest' unless supported_version?
        raise Invalid, 'invalid_source_manifest_header' unless valid_header?

        validate_tables!
        validate_unavailable!
        return if @data['extra_roots'].all? { |path| valid_path?(path) }

        raise Invalid, 'invalid_source_roots'
      end

      def validate_unavailable!
        return if (%w[state unavailable reference_cache_sha256 capture_sha256] & @data.keys).empty?

        valid = unavailable? && self.class.valid_unavailable_evidence?(@data['unavailable']) && empty_comparison?
        valid &&= valid_optional_digests?
        raise Invalid, 'invalid_unavailable_source_manifest' unless valid
      end

      def valid_optional_digests?
        %w[reference_cache_sha256 capture_sha256].all? { |key| !@data.key?(key) || digest?(@data[key]) }
      end

      def empty_comparison?
        !@data['complete'] && !@data['comparison_complete'] && @data['scopes'].empty? && @data['identities'].empty?
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
          valid_capture_time? && valid_comparison_coverage? &&
          %w[boot_verified complete].all? { |key| [true, false].include?(@data[key]) }
      end

      def valid_comparison_coverage?
        !@data.key?('comparison_complete') || [true, false].include?(@data['comparison_complete'])
      end

      # Optional so existing version-1 manifests remain readable. Consumers
      # needing a catch-up boundary must reconcile when it is absent.
      def valid_capture_time?
        value = @data['captured_at']
        value.nil? || (value.is_a?(Numeric) && value.finite? && value.positive?)
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
