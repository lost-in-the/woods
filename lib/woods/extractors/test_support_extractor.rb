# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'

require_relative 'factory_extractor'
require_relative 'test_support_catalog'

module Woods
  module Extractors
    # TestSupportExtractor indexes the files a test suite is built from but
    # which are not tests: helper modules, shared examples and contexts,
    # custom matchers, suite configuration, support classes and scripts.
    #
    # One unit per file under `config.test_support_paths`, identified by its
    # Rails.root-relative path. A file in a factory directory that declares no
    # factory (`FactoryBot.define { after(:build) { ... } }`) is indexed here
    # too, since the factory extractor emits nothing for it.
    #
    # `metadata[:included_for]` depends on every support file's
    # `config.include` lines, so the unit set is a function of the whole
    # support set: incremental runs re-run this extractor wholesale.
    #
    # @example
    #   units = TestSupportExtractor.new.extract_all
    #   helpers = units.find { |u| u.identifier == "spec/support/analytics_helpers.rb" }
    #   helpers.metadata[:kind]         # => "helper_module"
    #   helpers.metadata[:included_for] # => ["feature"]
    #
    class TestSupportExtractor
      def initialize
        @rails_root = Rails.root
        @catalog = TestSupportCatalog.new
      end

      # Extract every test support file.
      #
      # @return [Array<ExtractedUnit>] units ordered by identifier
      def extract_all
        entries = @catalog.entries + factory_definition_entries
        @catalog.errors.each { |error| log_failure(error[:path], error[:message]) }
        entries.uniq(&:identifier).sort_by(&:identifier).map { |entry| build_unit(entry) }
      end

      private

      # Factory-directory files the factory extractor produces no unit for.
      #
      # @return [Array<TestSupportCatalog::Entry>]
      def factory_definition_entries
        factories = FactoryExtractor.new
        factory_files.filter_map do |path|
          next unless factories.extract_factory_file(path).empty?

          @catalog.analyze(path)
        rescue StandardError => e
          log_failure(path, e.message)
          nil
        end
      end

      def factory_files
        FactoryExtractor::FACTORY_DIRECTORIES.flat_map { |dir| Dir[@rails_root.join(dir, '**', '*.rb').to_s] }
                                             .select { |path| @catalog.contained?(path) }.sort
      end

      def log_failure(path, message)
        SourceInputs::ConsumerErrors.log(self, "Failed to extract test support from #{path}: #{message}")
      end

      # @param entry [TestSupportCatalog::Entry]
      # @return [ExtractedUnit]
      def build_unit(entry)
        unit = ExtractedUnit.new(type: :test_support, identifier: entry.identifier, file_path: entry.file_path)
        unit.source_code = entry.source
        unit.metadata = build_metadata(entry)
        unit.dependencies = @catalog.references(entry.source, except: entry.identifier).dependencies
        unit
      end

      # @param entry [TestSupportCatalog::Entry]
      # @return [Hash]
      def build_metadata(entry)
        kinds = entry.kinds
        {
          kind: kinds.first,
          kinds: kinds,
          names: entry.names,
          helper_modules: entry.helper_modules,
          classes: entry.classes,
          shared_examples: entry.shared_examples,
          shared_contexts: entry.shared_contexts,
          matchers: entry.matchers,
          methods: entry.method_names,
          includes: entry.includes,
          included_for: @catalog.included_for(entry.helper_modules),
          test_framework: entry.identifier.start_with?('test/') ? 'minitest' : 'rspec'
        }
      end
    end
  end
end
