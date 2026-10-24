# frozen_string_literal: true

require 'json'

module Woods
  module Impact
    # Validated typed unit inventory from one locked published payload.
    class Endpoint
      # One parse per unit across a range's two endpoints. A publish writes
      # every unit again with its own `extracted_at`, so a unit nothing
      # changed still differs from its previous file in that one value.
      # Masking it, a `from` file whose bytes then equal the `to` file's
      # shares that parsed (and validated) object; any other file is parsed
      # on its own. Shared objects are deeply frozen.
      class SharedParse
        # The writer's last two top-level members, pretty or compact: the
        # anchor at the end of the document keeps a nested `extracted_at`
        # from matching. A file of any other shape is never masked.
        STAMP = /"extracted_at":\s*"([^"\\]*)",\s*"source_hash":\s*"[0-9a-f]{64}"\s*\}\s*\z/n
        # Bytes at the end of a file that can hold those two members.
        TAIL = 256

        def initialize
          @parsed = {}
        end

        # @param content [String] a `to` unit file's checked bytes
        # @return [Object] its frozen data, remembered for {#reuse}
        def remember(content)
          @parsed[masked(content)] = JSON.parse(content, freeze: true)
        end

        # @param content [String] a `from` unit file's checked bytes
        # @return [Object] the data remembered for equivalent bytes, or its own frozen parse
        def reuse(content)
          @parsed.fetch(masked(content)) { JSON.parse(content, freeze: true) }
        end

        private

        # The file's bytes without its extraction time. Only the tail is
        # searched, as bytes, so the cost does not grow with the unit.
        def masked(content)
          start = [content.bytesize - TAIL, 0].max
          match = STAMP.match(content.byteslice(start, TAIL).b)
          return content.freeze unless match

          (content.byteslice(0, start + match.begin(1)) << content.byteslice((start + match.end(1))..)).freeze
        end
      end

      # @param reader [PublishedIndex] caller retains ownership of its lock
      def initialize(reader)
        @reader = reader
      end

      # Historical tokens are unavailable; the checksum covers only the manifest.
      # @param selector [String, Integer]
      # @return [Hash] endpoint provenance without host paths
      def provenance(selector)
        { 'selector' => selector, 'generation' => @reader.generation_number,
          'git_sha' => @reader.manifest['git_sha'], 'manifest_checksum' => @reader.external_dependency_checksum }
      end

      # The manifest checks {#units} makes, without reading a unit.
      # @return [Hash] the manifest
      # @raise [IOError] if the manifest is not an object with valid counts
      def manifest
        @reader.manifest.tap { |manifest| validate_manifest!(manifest) }
      end

      # @param decode [#call, nil] how each unit file's checked bytes become
      #   its data ({SharedParse}); nil parses them
      # @return [Hash{Array(String, String) => Hash}] actual typed identities
      # @raise [IOError] if required inventory or fields are unavailable
      def units(decode: nil)
        manifest = self.manifest
        records = @reader.each_unit(decode: decode).to_a
        raise IOError, 'Impact payload total_units mismatch' unless records.size == manifest['total_units']

        records.each_with_object({}) do |unit, result|
          validate_unit!(unit)
          identity = unit.values_at('identifier', 'type')
          raise IOError, 'Duplicate impact typed identity' if result.key?(identity)

          result[identity] = unit
        end
      end

      # @param units [Hash] validated typed units
      # @param side [String] from or to
      # @return [Array<Hash>] unavailable source facts, including unchanged units
      def unknowns(units, side)
        result = units.values.filter_map do |unit|
          next unless unit['source_code'].nil?

          unit.slice('identifier', 'type').merge('kind' => 'source_unavailable', 'endpoint' => side)
        end
        result.sort_by { |entry| entry.values_at('identifier', 'type') }
      end

      private

      def validate_manifest!(manifest)
        raise IOError, 'Impact requires an object manifest' unless manifest.is_a?(Hash)

        counts = manifest['counts']
        total = manifest['total_units']
        valid = counts.is_a?(Hash) && total.is_a?(Integer) && total >= 0 &&
                valid_counts?(counts) && counts.values.sum == total
        raise IOError, 'Impact requires manifest counts and total_units' unless valid
      end

      def valid_counts?(counts)
        counts.values.all? { |count| count.is_a?(Integer) && count >= 0 }
      end

      def validate_unit!(unit)
        valid = unit.key?('source_code') && (unit['source_code'].nil? || unit['source_code'].is_a?(String)) &&
                unit['metadata'].is_a?(Hash) && unit['dependencies'].is_a?(Array)
        raise IOError, 'Impact requires source_code, metadata and dependencies on every unit' unless valid
      end
    end
  end
end
