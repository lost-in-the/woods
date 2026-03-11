# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # FactoryExtractor handles extraction of FactoryBot factory definitions.
    #
    # Scans spec/factories/ and test/factories/ for FactoryBot definitions
    # and produces one ExtractedUnit per factory block. Uses a line-by-line
    # state machine parser (never evals factory files).
    #
    # Supports: basic factories, explicit class override, traits, associations,
    # sequences, callbacks, parent inheritance, transient attributes, and
    # nested factory definitions (each becomes its own unit).
    #
    # @example
    #   extractor = FactoryExtractor.new
    #   units = extractor.extract_all
    #   user = units.find { |u| u.identifier == "user" }
    #   user.metadata[:traits] # => ["admin", "with_avatar"]
    #
    class FactoryExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      FACTORY_DIRECTORIES = %w[spec/factories test/factories].freeze

      def initialize
        @directories = FACTORY_DIRECTORIES.map { |d| Rails.root.join(d) }.select(&:directory?)
      end

      # Extract all factory definitions from all discovered directories.
      #
      # @return [Array<ExtractedUnit>] List of factory units
      def extract_all
        @directories.flat_map do |dir|
          Dir[dir.join('**/*.rb')].flat_map { |file| extract_factory_file(file) }
        end
      end

      # Extract factory definitions from a single factory file.
      #
      # Returns an Array because each file may contain multiple factory definitions.
      #
      # @param file_path [String] Path to the factory file
      # @return [Array<ExtractedUnit>] List of factory units
      def extract_factory_file(file_path)
        return [] unless file_path.to_s.end_with?('.rb')

        source = File.read(file_path)
        factories = parse_factories(source)

        factories.map { |factory_data| build_unit(factory_data, file_path, source) }
      rescue StandardError => e
        Rails.logger.error("Failed to extract factories from #{file_path}: #{e.message}")
        []
      end

      private

      # Parse factory definitions from source using a line-by-line state machine.
      #
      # Tracks factory nesting, traits, associations, sequences, callbacks, and
      # transient attributes. Each factory block (including nested factories within
      # a parent factory) produces one entry in the returned array.
      #
      # @param source [String] Factory file source code
      # @return [Array<Hash>] Parsed factory data hashes
      def parse_factories(source)
        completed = []
        factory_stack = []
        depth = 0
        in_transient = false
        transient_depth = nil

        source.lines.each_with_index do |line, index|
          stripped = line.strip

          # Factory definition — push new factory onto stack
          if (factory_data = match_factory(stripped, depth, index + 1))
            factory_stack.push(factory_data)
            depth += 1
            next
          end

          # Trait definition — record trait in current factory, open block
          if (trait_match = stripped.match(/\Atrait\s+:(\w+)\s+do/))
            factory_stack.last[:traits] << trait_match[1] if factory_stack.any?
            depth += 1
            next
          end

          # Transient block — start collecting transient attributes
          if stripped.match?(/\Atransient\s+do/)
            in_transient = true
            transient_depth = depth
            depth += 1
            next
          end

          # Collect transient attribute names (word { ... } or word do)
          if in_transient && factory_stack.any? && (attr_match = stripped.match(/\A(\w+)\s*(?:\{|do\b)/))
            factory_stack.last[:transient_attributes] << attr_match[1]
          end

          # Association
          if factory_stack.any? && (assoc_match = stripped.match(/\Aassociation\s+:(\w+)/))
            factory_stack.last[:associations] << assoc_match[1]
          end

          # Sequence
          if factory_stack.any? && (seq_match = stripped.match(/\Asequence\s*\(:(\w+)\)/))
            factory_stack.last[:sequences] << seq_match[1]
          end

          # Callbacks: after(:hook), before(:hook), after_stub(:hook)
          if factory_stack.any? && (cb_match = stripped.match(/\A(?:after|before|after_stub)\s*\([:'"](\w+)/))
            factory_stack.last[:callbacks] << cb_match[1]
          end

          # Generic block openers — factory/trait/transient already handled above with next
          if block_opener?(stripped)
            depth += 1
            next
          end

          next unless stripped == 'end'

          depth -= 1

          # Close transient block if we've returned to the depth where it was opened
          if in_transient && depth == transient_depth
            in_transient = false
            transient_depth = nil
          end

          # Close factory if top factory was opened at this depth
          next unless factory_stack.any? && depth == factory_stack.last[:open_depth]

          completed << factory_stack.pop
        end

        completed
      end

      # Try to match a factory definition line and return initialized factory data.
      #
      # Handles:
      #   factory :name do
      #   factory :name, class: ClassName do
      #   factory :name, class: 'ClassName' do
      #   factory :name, parent: :other do
      #
      # @param line [String] Stripped source line
      # @param depth [Integer] Current block depth when factory would be opened
      # @param line_number [Integer] 1-based line number
      # @return [Hash, nil] Initialized factory data or nil if not a factory line
      def match_factory(line, depth, line_number)
        return nil unless line.match?(/\Afactory\s+:/) && line.match?(/\bdo\b/)

        name_match = line.match(/\Afactory\s+:(\w+)/)
        return nil unless name_match

        name = name_match[1]
        options = {}

        if (class_match = line.match(/\bclass:\s*['"]?([\w:]+)['"]?/))
          options[:class_name] = class_match[1]
        end

        if (parent_match = line.match(/\bparent:\s*:(\w+)/))
          options[:parent] = parent_match[1]
        end

        {
          name: name,
          class_name: options[:class_name] || classify(name),
          parent_factory: options[:parent],
          open_depth: depth,
          line_number: line_number,
          traits: [],
          associations: [],
          sequences: [],
          callbacks: [],
          transient_attributes: []
        }
      end

      # Convert a snake_case factory name to a CamelCase class name.
      #
      # @param name [String] Snake_case factory name (e.g., "admin_user")
      # @return [String] CamelCase class name (e.g., "AdminUser")
      def classify(name)
        name.split('_').map(&:capitalize).join
      end

      # Check if a stripped line opens a new block.
      #
      # Excludes factory, trait, and transient lines — those are handled
      # explicitly in the main parser loop with depth tracking of their own.
      #
      # @param stripped [String] Stripped line content
      # @return [Boolean]
      def block_opener?(stripped)
        return false if stripped.match?(/\Afactory\s+:/)
        return false if stripped.match?(/\Atrait\s+:/)
        return false if stripped.match?(/\Atransient\s+do/)
        return true if stripped.match?(/\b(do|def|case|begin|class|module|while|until|for)\b.*(?<!\bend)\s*$/)

        stripped.match?(/\A(if|unless)\b/)
      end

      # Build an ExtractedUnit from parsed factory data.
      #
      # @param factory_data [Hash] Parsed factory data
      # @param file_path [String] Path to the factory file
      # @param file_source [String] Full file source
      # @return [ExtractedUnit]
      def build_unit(factory_data, file_path, file_source)
        unit = ExtractedUnit.new(
          type: :factory,
          identifier: factory_data[:name],
          file_path: file_path
        )

        unit.source_code = build_source_annotation(factory_data, file_source)
        unit.metadata = build_metadata(factory_data)
        unit.dependencies = extract_dependencies(factory_data)

        unit
      end

      # Build annotated source code for the unit.
      #
      # @param factory_data [Hash] Parsed factory data
      # @param file_source [String] Full file source
      # @return [String]
      def build_source_annotation(factory_data, file_source)
        header = "# Factory: #{factory_data[:name]} (model: #{factory_data[:class_name]})"
        header += "\n# Parent: #{factory_data[:parent_factory]}" if factory_data[:parent_factory]
        "#{header}\n#{file_source}"
      end

      # Build metadata hash for the unit.
      #
      # @param factory_data [Hash] Parsed factory data
      # @return [Hash]
      def build_metadata(factory_data)
        {
          factory_name: factory_data[:name],
          model_class: factory_data[:class_name],
          traits: factory_data[:traits],
          associations: factory_data[:associations],
          sequences: factory_data[:sequences],
          parent_factory: factory_data[:parent_factory],
          callbacks: factory_data[:callbacks].uniq,
          transient_attributes: factory_data[:transient_attributes]
        }
      end

      # Extract dependencies from factory data.
      #
      # Creates:
      # - :model dependency (via :factory_for) linking to the modeled class
      # - :factory dependency (via :factory_parent) for parent factory inheritance
      # - :factory dependencies (via :factory_association) for each association
      #
      # @param factory_data [Hash] Parsed factory data
      # @return [Array<Hash>]
      def extract_dependencies(factory_data)
        deps = []

        deps << { type: :model, target: factory_data[:class_name], via: :factory_for }

        if factory_data[:parent_factory]
          deps << { type: :factory, target: factory_data[:parent_factory], via: :factory_parent }
        end

        factory_data[:associations].each do |assoc|
          deps << { type: :factory, target: assoc, via: :factory_association }
        end

        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
