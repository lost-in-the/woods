# frozen_string_literal: true

require 'strscan'

require_relative 'line_neutralizer'
require_relative 'config_file_extractor'

module Woods
  module Extractors
    # Finds reads of YAML configuration files in Ruby source and names the
    # `config_file` unit each one targets.
    #
    # Three read shapes are recognized:
    #
    # * `config_for(:name)` and `config_for("name")`, which read `config/<name>.yml`
    # * `YAML.load_file` / `safe_load_file` / `unsafe_load_file` (also on `Psych`)
    #   with a literal path, a `Rails.root.join` of literals, or a literal
    #   prefixed by an interpolated `Rails.root`
    # * a read through a settings constant listed in
    #   `Woods.configuration.settings_readers`
    #
    # The target is derived from the reader's own source and configuration
    # only. No file is opened and no other unit is consulted, so a reader's
    # edges are a pure function of its source. A path that is not an indexable
    # config file ({ConfigFileExtractor.config_file_path?}) yields no edge.
    module ConfigReadScanner
      CONFIG_FOR = %r{\bconfig_for\s*+\(?+\s*+(?::([A-Za-z_]\w*+)|"([\w/.-]++)"|'([\w/.-]++)')}
      LOAD_FILE = /\b(?:YAML|Psych)\s*+\.\s*+(?:unsafe_|safe_)?+load_file\s*+\(?+\s*+/
      ROOT_JOIN = /Rails\s*+\.\s*+root\s*+\.\s*+join\s*+\(\s*+/
      STRING_LITERAL = /"([^"\\\n]*+)"|'([^'\\\n]*+)'/
      SEPARATOR = /\s*+,\s*+/
      ROOT_INTERPOLATION = '#{Rails.root}/' # rubocop:disable Lint/InterpolationCheck

      # Mixed into extractors through {SharedDependencyScanner}. The scan
      # itself lives on the module, so no helper name leaks into an extractor.
      #
      # @param source [String] Ruby source code
      # @return [Array<Hash>] `{ type: :config_file, target:, via: :reads_config }`, sorted by target
      def scan_config_dependencies(source)
        ConfigReadScanner.call(source)
      end

      class << self
        # @param source [String] Ruby source code
        # @return [Array<Hash>] `{ type: :config_file, target:, via: :reads_config }`, sorted by target
        def call(source)
          return [] unless candidate?(source)

          scannable = LineNeutralizer.strip_comments(source)
          paths = config_for_paths(scannable) + load_file_paths(scannable) + settings_reader_paths(scannable)
          paths.uniq.sort.filter_map do |path|
            next unless ConfigFileExtractor.config_file_path?(path)

            { type: :config_file, target: path, via: :reads_config }
          end
        end

        private

        # Most source reads no configuration file. Skip the comment pass for it.
        def candidate?(source)
          source.include?('config_for') || source.include?('load_file') ||
            Array(Woods.configuration&.settings_readers).any? { |reader| source.include?(reader[:constant].to_s) }
        end

        def config_for_paths(source)
          return [] unless source.include?('config_for')

          source.scan(CONFIG_FOR).map { |captures| "config/#{captures.compact.first}.yml" }
        end

        def load_file_paths(source)
          return [] unless source.include?('load_file')

          paths = []
          scanner = StringScanner.new(source)
          while scanner.scan_until(LOAD_FILE)
            path = scanner.scan(ROOT_JOIN) ? joined_literals(scanner) : single_literal(scanner)
            path = normalize_path(path)
            paths << path if path
          end
          paths
        end

        def single_literal(scanner)
          scanner.scan(STRING_LITERAL) && (scanner[1] || scanner[2])
        end

        # @return [String, nil] the joined segments, or nil when any argument is not a literal
        def joined_literals(scanner)
          segments = []
          loop do
            segment = single_literal(scanner)
            return nil unless segment

            segments << segment
            break unless scanner.scan(SEPARATOR)
          end
          scanner.scan(/\s*+\)/) ? segments.join('/') : nil
        end

        def normalize_path(path)
          return nil if path.nil? || path.empty?

          path = path.delete_prefix(ROOT_INTERPOLATION)
          return nil if path.include?('#{') || path.start_with?('/') || path.split('/').include?('..')

          path
        end

        def settings_reader_paths(source)
          Array(Woods.configuration&.settings_readers).filter_map do |reader|
            constant = reader[:constant].to_s
            next if constant.empty? || !source.include?(constant)

            reader[:file].to_s if source.match?(settings_pattern(constant))
          end
        end

        # A read is the constant followed by a method call or an index, at the
        # top of a constant path: `Settings.x`, `::Settings[:x]`, never `Other::Settings.x`.
        def settings_pattern(constant)
          name = Regexp.escape(constant.delete_prefix('::'))
          /(?<![\w:])(?:::)?+#{name}\s*+[.\[]/
        end
      end
    end
  end
end
