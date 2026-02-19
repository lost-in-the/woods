# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # TestMappingExtractor maps test files to the units they exercise.
    #
    # Scans spec/**/*_spec.rb (RSpec) and test/**/*_test.rb (Minitest) to
    # produce one ExtractedUnit per test file. Extracts subject class,
    # test count, shared example usage, and test framework type.
    #
    # Units are linked to the code under test via :test_coverage dependencies,
    # inferred from the subject class name and file directory structure.
    #
    # @example
    #   extractor = TestMappingExtractor.new
    #   units = extractor.extract_all
    #   spec = units.find { |u| u.identifier == "spec/models/user_spec.rb" }
    #   spec.metadata[:subject_class]  # => "User"
    #   spec.metadata[:test_count]     # => 12
    #
    class TestMappingExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      RSPEC_GLOB = 'spec/**/*_spec.rb'
      MINITEST_GLOB = 'test/**/*_test.rb'

      def initialize
        @rails_root = Rails.root
      end

      # Extract all test mapping units from spec/ and test/ directories.
      #
      # @return [Array<ExtractedUnit>] List of test mapping units
      def extract_all
        rspec_units + minitest_units
      end

      # Extract a single test file into a test mapping unit.
      #
      # @param file_path [String] Absolute path to the spec or test file
      # @return [ExtractedUnit, nil] The extracted unit or nil on error
      def extract_test_file(file_path)
        source = File.read(file_path)
        framework = detect_framework(file_path)
        relative_path = file_path.sub("#{@rails_root}/", '')

        unit = ExtractedUnit.new(
          type: :test_mapping,
          identifier: relative_path,
          file_path: file_path
        )

        unit.source_code = source
        unit.metadata = extract_metadata(source, file_path, framework)
        unit.dependencies = extract_dependencies(unit.metadata[:subject_class], unit.metadata[:test_type])

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract test mapping from #{file_path}: #{e.message}")
        nil
      end

      private

      def rspec_units
        Dir[@rails_root.join(RSPEC_GLOB)].filter_map { |f| extract_test_file(f) }
      end

      def minitest_units
        Dir[@rails_root.join(MINITEST_GLOB)].filter_map { |f| extract_test_file(f) }
      end

      # Determine test framework from file path.
      #
      # @param file_path [String] Path to the test file
      # @return [Symbol] :rspec or :minitest
      def detect_framework(file_path)
        file_path.end_with?('_spec.rb') ? :rspec : :minitest
      end

      # Extract all metadata from a test file.
      #
      # @param source [String] File source code
      # @param file_path [String] Absolute path to the file
      # @param framework [Symbol] :rspec or :minitest
      # @return [Hash]
      def extract_metadata(source, file_path, framework)
        subject_class = extract_subject_class(source, framework)
        test_type = infer_test_type(file_path)

        {
          subject_class: subject_class,
          test_count: count_tests(source, framework),
          test_type: test_type,
          test_framework: framework,
          shared_examples: extract_shared_examples_defined(source),
          shared_examples_used: extract_shared_examples_used(source)
        }
      end

      # Extract the primary subject class under test.
      #
      # For RSpec: reads the top-level describe/RSpec.describe argument.
      # For Minitest: reads the class name and strips the "Test" suffix.
      #
      # @param source [String] File source code
      # @param framework [Symbol] :rspec or :minitest
      # @return [String, nil] Class name or nil if not detected
      def extract_subject_class(source, framework)
        framework == :rspec ? extract_rspec_subject(source) : extract_minitest_subject(source)
      end

      # Extract subject class from top-level describe in an RSpec file.
      #
      # Tries constant reference first (describe User do), then string/symbol
      # form (describe 'User' do). Handles both RSpec.describe and bare describe.
      #
      # @param source [String] RSpec file source code
      # @return [String, nil]
      def extract_rspec_subject(source)
        # Constant reference: describe User do, RSpec.describe UsersController do
        match = source.match(/^\s*(?:RSpec\.)?describe\s+([\w:]+)\s/)
        return match[1] if match

        # String/symbol form: describe 'User' do
        match = source.match(/^\s*(?:RSpec\.)?describe\s+['"]([^'"]+)['"]\s/)
        match ? match[1] : nil
      end

      # Extract subject class from Minitest test class name.
      #
      # Strips conventional "Test" suffix: "UserTest" => "User".
      #
      # @param source [String] Minitest file source code
      # @return [String, nil]
      def extract_minitest_subject(source)
        match = source.match(/class\s+(\w+Test)\s*</)
        return nil unless match

        match[1].sub(/Test\z/, '')
      end

      # Count test examples in the file.
      #
      # For RSpec: counts it/specify/example blocks.
      # For Minitest: counts test "..." strings and def test_ methods.
      #
      # @param source [String] File source code
      # @param framework [Symbol] :rspec or :minitest
      # @return [Integer]
      def count_tests(source, framework)
        if framework == :rspec
          source.scan(/^\s*(?:it|specify|example)\s+['"]/).size
        else
          source.scan(/^\s*test\s+['"]/).size +
            source.scan(/^\s*def\s+test_\w/).size
        end
      end

      # Extract names of shared examples defined in the file.
      #
      # @param source [String] File source code
      # @return [Array<String>]
      def extract_shared_examples_defined(source)
        source.scan(/^\s*shared_examples(?:_for)?\s+['"]([^'"]+)['"]/).flatten
      end

      # Extract names of shared examples used (included) in the file.
      #
      # @param source [String] File source code
      # @return [Array<String>]
      def extract_shared_examples_used(source)
        source.scan(/^\s*(?:include_examples|it_behaves_like)\s+['"]([^'"]+)['"]/).flatten
      end

      # Infer test type from the directory structure of the file path.
      #
      # @param file_path [String] Absolute path to the test file
      # @return [Symbol] One of :model, :controller, :request, :system, :unit
      def infer_test_type(file_path)
        case file_path
        when %r{/spec/models/}, %r{/test/models/} then :model
        when %r{/spec/controllers/}, %r{/test/controllers/} then :controller
        when %r{/spec/requests/}, %r{/test/integration/} then :request
        when %r{/spec/system/}, %r{/test/system/} then :system
        else :unit
        end
      end

      # Extract dependencies by linking the test file to the unit under test.
      #
      # Dependency type is inferred from the subject class name suffix.
      # Falls back to :model when the suffix is ambiguous.
      #
      # @param subject_class [String, nil] The class under test
      # @param test_type [Symbol] The inferred test file category
      # @return [Array<Hash>]
      def extract_dependencies(subject_class, test_type)
        return [] unless subject_class

        target_type = case subject_class
                      when /Controller\z/ then :controller
                      when /Job\z/ then :job
                      when /Mailer\z/ then :mailer
                      when /Service\z/, /Interactor\z/ then :service
                      else infer_type_from_test_type(test_type)
                      end

        [{ type: target_type, target: subject_class, via: :test_coverage }]
      end

      # Infer dependency type from test_type when class name suffix is ambiguous.
      #
      # @param test_type [Symbol] The test type
      # @return [Symbol]
      def infer_type_from_test_type(test_type)
        test_type == :controller ? :controller : :model
      end
    end
  end
end
