# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module Woods
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

      # Constant-form describe: `describe User do`, `RSpec.describe User, type: :model do`.
      # The constant must start uppercase (quoted strings can't sneak in) and may be
      # followed by whitespace OR a comma — the rspec-rails generator default is
      # `RSpec.describe User, type: :model do` (B-082 / #194). Capybara's
      # `feature` / `RSpec.feature` is an example group in the same position.
      RSPEC_CONSTANT_DESCRIBE = /^\s*(?:RSpec\.)?(?:describe|feature)\s+([A-Z][\w:]*)(?=[\s,]|$)/

      # String-form describe: `describe 'User' do`, `RSpec.describe 'GET /users', type: :request do`,
      # `RSpec.feature 'Widget checkout' do`.
      # The closing quote delimits the subject, so nothing is required after it.
      RSPEC_STRING_DESCRIBE = /^\s*(?:RSpec\.)?(?:describe|feature)\s+['"]([^'"]+)['"]/

      # A subject names a class only when it is a constant path (`Widget`,
      # `'Ledger::Entry'`). Free text (`'Widget checkout'`) is a description:
      # it names no unit, so it must never become a :test_coverage target.
      CONSTANT_PATH = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/

      # Outside a typed directory, the first example group's `type:` metadata
      # or a Capybara `feature` block decides the test type.
      RSPEC_DECLARED_TYPE = /\btype:\s*:(feature|system)\b/
      RSPEC_FEATURE_GROUP = /^\s*(?:RSpec\.)?feature\s/

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
        SourceInputs::ConsumerErrors.log(self, "Failed to extract test mapping from #{file_path}: #{e.message}")
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
        subject = extract_subject(source, framework)
        subject_class = subject if subject&.match?(CONSTANT_PATH)
        test_type = infer_test_type(file_path, source)

        metadata = {
          subject_class: subject_class,
          test_count: count_tests(source, framework),
          test_type: test_type,
          test_framework: framework,
          shared_examples: extract_shared_examples_defined(source),
          shared_examples_used: extract_shared_examples_used(source)
        }
        metadata[:description] = subject if subject && !subject_class
        metadata
      end

      # Extract the primary subject under test, as written.
      #
      # For RSpec: reads the top-level describe/RSpec.describe argument.
      # For Minitest: reads the class name and strips the "Test" suffix.
      #
      # @param source [String] File source code
      # @param framework [Symbol] :rspec or :minitest
      # @return [String, nil] Constant path or free-text description, nil if not detected
      def extract_subject(source, framework)
        framework == :rspec ? extract_rspec_subject(source) : extract_minitest_subject(source)
      end

      # Extract the subject from the first describe or feature in an RSpec file.
      #
      # Scans line by line and takes the file's FIRST describe, whatever its
      # form — constant reference (describe User do, RSpec.describe User,
      # type: :model do) or string (describe 'User' do). An inner
      # `describe 'validations'` nested under a constant-form outer describe
      # must never become the subject: it would mint a phantom graph node and
      # lose the real coverage edge. Handles RSpec.describe, bare describe,
      # and their feature forms.
      #
      # @param source [String] RSpec file source code
      # @return [String, nil]
      def extract_rspec_subject(source)
        group = first_example_group(source)
        return nil unless group

        (group.match(RSPEC_CONSTANT_DESCRIBE) || group.match(RSPEC_STRING_DESCRIBE))[1]
      end

      # Find the line that opens the file's first describe or feature block.
      #
      # @param source [String] RSpec file source code
      # @return [String, nil]
      def first_example_group(source)
        source.each_line.find do |line|
          line.match?(RSPEC_CONSTANT_DESCRIBE) || line.match?(RSPEC_STRING_DESCRIBE)
        end
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

      # Infer test type from the directory structure of the file path, then
      # from the first example group for files outside a typed directory.
      #
      # @param file_path [String] Absolute path to the test file
      # @param source [String] File source code
      # @return [Symbol] One of :model, :controller, :request, :system, :feature, :unit
      def infer_test_type(file_path, source)
        case file_path
        when %r{/spec/models/}, %r{/test/models/} then :model
        when %r{/spec/controllers/}, %r{/test/controllers/} then :controller
        when %r{/spec/requests/}, %r{/test/integration/} then :request
        when %r{/spec/system/}, %r{/test/system/} then :system
        when %r{/spec/features/} then :feature
        else declared_test_type(source)
        end
      end

      # Read the test type the first example group declares.
      #
      # @param source [String] File source code
      # @return [Symbol] :feature, :system, or :unit when nothing is declared
      def declared_test_type(source)
        group = first_example_group(source)
        return :unit unless group
        return :feature if group.match?(RSPEC_FEATURE_GROUP)

        group[RSPEC_DECLARED_TYPE, 1]&.to_sym || :unit
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
