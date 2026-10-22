# frozen_string_literal: true

require_relative '../published_index'

module Woods
  module Impact
    # A selector cannot identify one retained published payload.
    class ResolutionError < ArgumentError; end

    # Resolves both endpoints once and owns their PublishedIndex reader locks.
    # SHA is provenance, never a snapshot row ID or a payload generation.
    class Resolver
      # @param index_dir [String, Pathname]
      def initialize(index_dir)
        @index_dir = index_dir
        @readers = {}
      end

      # Resolve a range and release every reader, including on consumer failure.
      # "now" means the current generation opened once at the start of this call.
      #
      # @param from [Integer, String] generation number, gen:N or SHA prefix
      # @param to [Integer, String] generation number, gen:N, SHA prefix or now
      # @yieldparam before [PublishedIndex]
      # @yieldparam after [PublishedIndex]
      # @return [Object] consumer result
      def open(from:, to: 'now')
        capture_catalog
        yield resolve(from), resolve(to)
      ensure
        @readers.each_value(&:close)
        @readers.clear
      end

      private

      def capture_catalog
        current = PublishedIndex.new(@index_dir)
        @readers[current.generation_number] = current
        @current = current.generation_number
        raise ResolutionError, 'Impact ranges require numbered retained payloads' if @current.zero?

        PublishedIndex.available_generations(@index_dir).each do |number|
          next if number > @current || @readers.key?(number)

          @readers[number] = PublishedIndex.new(@index_dir, generation: number)
        end
      end

      def resolve(selector)
        return @readers.fetch(@current) if selector == 'now'

        number = generation_number(selector)
        return @readers.fetch(number) { resolution_error(selector) } if number

        resolve_sha(selector)
      end

      def generation_number(selector)
        return selector if selector.is_a?(Integer) && selector.positive?
        return unless selector.is_a?(String) && selector.match?(/\Agen:[1-9]\d*\z/)

        selector.delete_prefix('gen:').to_i
      end

      def resolve_sha(selector)
        unless selector.is_a?(String) && selector.match?(/\A[0-9a-f]{7,40}\z/i)
          raise ResolutionError, 'Use a positive generation number, gen:N, a 7–40 character SHA, or now'
        end

        matches = @readers.values.select { |reader| sha_matches?(manifest_sha(reader), selector) }
        return matches.first if matches.one?

        resolution_error(selector, matches.empty? ? @readers.values : matches)
      end

      def manifest_sha(reader)
        manifest = reader.manifest
        raise IOError, 'Impact requires an object manifest' unless manifest.is_a?(Hash)

        manifest['git_sha']
      end

      def sha_matches?(sha, selector)
        sha.is_a?(String) && sha.match?(/\A[0-9a-f]{7,40}\z/i) && sha.downcase.start_with?(selector.downcase)
      end

      def resolution_error(selector, alternatives = @readers.values)
        choices = alternatives.sort_by(&:generation_number).map { |reader| "gen:#{reader.generation_number}" }
        message = "Selector #{selector.inspect} does not identify one retained payload; use #{choices.join(', ')}"
        raise ResolutionError, message
      end
    end
  end
end
