# frozen_string_literal: true

require_relative 'source_nesting'

module Woods
  module Extractors
    # What the test suite's support files define, and who refers to it.
    #
    # Shared examples, shared contexts, custom matchers and helper modules are
    # referenced by NAME from other files, so resolving a reference needs the
    # whole support set. The catalog reads that set from source, once per
    # instance: {TestSupportExtractor} turns its entries into units, and
    # {TestMappingExtractor} resolves a spec's references through it. Neither
    # reads the other's published output, so a full and an incremental
    # extraction agree as long as both re-run when a support file changes.
    #
    # @example
    #   catalog = TestSupportCatalog.new
    #   catalog.references(File.read(spec_path, encoding: Encoding::UTF_8)).dependencies
    #   # => [{ type: :test_support, target: "spec/support/shared/pages.rb", via: :behaves_like }]
    #
    class TestSupportCatalog
      include SourceNesting

      # Must equal `Woods::Configuration#test_support_paths`' default; used
      # when no configuration is loaded.
      DEFAULT_PATHS = %w[spec/support/**/*.rb spec/*_helper.rb spec/lib/**/*.rb
                         test/support/**/*.rb test/*_helper.rb test/lib/**/*.rb].freeze

      # Test files belong to {TestMappingExtractor}, whatever a glob matches.
      TEST_FILE_SUFFIXES = %w[_spec.rb _test.rb].freeze

      # `**/` spans directories, `{a,b}` alternation works.
      GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

      # Every kind a file can have, most specific first. The first one a file
      # has is its `kind`.
      KINDS = %w[shared_examples shared_context matcher helper_module class configuration script].freeze

      # A name argument: "double quoted", 'single quoted', or :symbol.
      NAME = /(?:"([^"\n]*)"|'([^'\n]*)'|:(\w+))/
      CONSTANT = /(?:::)?[A-Z]\w*(?:::[A-Z]\w*)*/
      # `RSpec.configure { |c| c.include Helpers }` on one line.
      INLINE_CONFIGURE = /RSpec\.configure[ \t]*\{[ \t]*\|\w+\|[ \t]*/

      SHARED_EXAMPLES = /^[ \t]*(?:RSpec\.)?shared_examples(?:_for)?[ \t(]+#{NAME}/
      SHARED_CONTEXT = /^[ \t]*(?:RSpec\.)?shared_context[ \t(]+#{NAME}/
      MATCHER = /^[ \t]*(?:RSpec::Matchers\.(?:define|define_negated_matcher|alias_matcher)|
                 matcher|define_negated_matcher|alias_matcher)[ \t(]+:(\w+[?!]?)/x
      CONFIGURE = /^[ \t]*(?:RSpec\.configure|FactoryBot\.define)\b/
      METHOD = /^[ \t]*def[ \t]+(?:self\.)?([a-z_]\w*[?!=]?)/
      CONFIG_INCLUDE = /^[ \t]*(?:#{INLINE_CONFIGURE})?[a-z_]\w*\.(include|extend|prepend)[ \t(]+(#{CONSTANT})([^\n]*)/
      INCLUDE_TYPES = /(?:\btype:|:type[ \t]*=>)[ \t]*([^\n]*)/

      BEHAVES_LIKE = /^[ \t]*(?:it_behaves_like|it_should_behave_like|include_examples)[ \t(]+#{NAME}/
      INCLUDE_CONTEXT = /^[ \t]*(?:#{INLINE_CONFIGURE})?(?:[a-z_]\w*\.)?include_context[ \t(]+#{NAME}/
      INCLUDE_MODULE = /^[ \t]*(?:#{INLINE_CONFIGURE})?(?:[a-z_]\w*\.)?(?:include|extend|prepend)[ \t(]+(#{CONSTANT})/

      # One support file's definitions.
      Entry = Struct.new(:identifier, :file_path, :source, :shared_examples, :shared_contexts, :matchers,
                         :helper_modules, :classes, :method_names, :includes, :configuration, keyword_init: true) do
        # @return [Array<String>] every kind this file has, most specific first
        def kinds
          found = { 'shared_examples' => shared_examples, 'shared_context' => shared_contexts,
                    'matcher' => matchers, 'helper_module' => helper_modules, 'class' => classes }
                  .reject { |_kind, names| names.empty? }.keys
          found << 'configuration' if configuration
          found.empty? ? ['script'] : found
        end

        # @return [Array<String>] every name the file defines
        def names
          (shared_examples + shared_contexts + matchers + helper_modules + classes).uniq
        end
      end

      # What one source refers to. The name lists are as written, resolved or
      # not; +dependencies+ holds only references a support file defines.
      Usage = Struct.new(:shared_examples, :shared_contexts, :helper_modules, :matchers, :dependencies,
                         keyword_init: true)

      class << self
        # The configured globs, or the defaults when no configuration is loaded.
        #
        # @return [Array<String>]
        def paths
          configured = Woods.configuration if Woods.respond_to?(:configuration)
          configured.respond_to?(:test_support_paths) ? configured.test_support_paths : DEFAULT_PATHS
        end

        # Is this a file the catalog reads? Static: it never touches the disk.
        #
        # @param relative_path [String] Rails.root-relative path
        # @return [Boolean]
        def support_path?(relative_path)
          relative_path.end_with?('.rb') &&
            TEST_FILE_SUFFIXES.none? { |suffix| relative_path.end_with?(suffix) } &&
            paths.any? { |glob| File.fnmatch?(glob, relative_path, GLOB_FLAGS) }
        end
      end

      # @return [Array<Hash>] `{ path:, message: }` for files that could not be analyzed
      attr_reader :errors

      def initialize
        @root = Rails.root.to_s
        @errors = []
      end

      # @return [Array<Entry>] one entry per support file, ordered by identifier
      def entries
        @entries ||= support_files.filter_map do |path|
          analyze(path)
        rescue StandardError => e
          @errors << { path: path, message: e.message }
          nil
        end
      end

      # Analyze one file's definitions.
      #
      # @param file_path [String] absolute path
      # @return [Entry]
      # @raise [ArgumentError] when the file is not valid UTF-8
      def analyze(file_path)
        source = File.read(file_path, encoding: Encoding::UTF_8)
        raise ArgumentError, 'source is not valid UTF-8' unless source.valid_encoding?

        declared = declarations(source)
        Entry.new(
          identifier: file_path.to_s.delete_prefix("#{@root}/"), file_path: file_path.to_s, source: source,
          shared_examples: names_in(source, SHARED_EXAMPLES), shared_contexts: names_in(source, SHARED_CONTEXT),
          matchers: source.scan(MATCHER).flatten.uniq,
          helper_modules: declared.fetch('module', []), classes: declared.fetch('class', []),
          method_names: source.scan(METHOD).flatten.uniq, includes: includes_in(source),
          configuration: source.match?(CONFIGURE)
        )
      end

      # Is this a regular file whose real path stays inside the application?
      # A symlink that leaves the root would publish source the application
      # does not own.
      #
      # @param file_path [String] absolute path
      # @return [Boolean]
      def contained?(file_path)
        File.file?(file_path) && File.realpath(file_path).start_with?("#{real_root}/")
      rescue SystemCallError
        false
      end

      # Test types the given modules are mixed into by any support file.
      #
      # @param module_names [Array<String>] qualified module names
      # @return [Array<String>] sorted types, `["all"]` when an include is untyped
      def included_for(module_names)
        wanted = module_names.to_set
        types = entries.flat_map(&:includes).filter_map do |inclusion|
          next unless module_matches(inclusion[:module]).intersect?(wanted)

          inclusion[:types].empty? ? ['all'] : inclusion[:types]
        end.flatten.uniq.sort
        types.include?('all') ? ['all'] : types
      end

      # Resolve what a source refers to.
      #
      # @param source [String] Ruby source of a test or support file
      # @param except [String, nil] identifier never linked to (the file itself)
      # @return [Usage]
      def references(source, except: nil)
        used = {
          behaves_like: names_in(source, BEHAVES_LIKE), includes_context: names_in(source, INCLUDE_CONTEXT),
          includes_helper: source.scan(INCLUDE_MODULE).flatten.uniq, uses_matcher: matchers_in(source)
        }
        dependencies = used.flat_map do |via, names|
          names.flat_map { |name| index.fetch(via)[lookup_key(via, name)].to_a }.uniq.sort.map do |identifier|
            { type: :test_support, target: identifier, via: via }
          end
        end
        Usage.new(shared_examples: used[:behaves_like], shared_contexts: used[:includes_context],
                  helper_modules: used[:includes_helper], matchers: used[:uses_matcher],
                  dependencies: dependencies.reject { |dep| dep[:target] == except }.uniq { |dep| dep[:target] })
      end

      private

      def support_files
        self.class.paths.flat_map { |glob| Dir.glob(File.join(@root, glob), GLOB_FLAGS) }
            .select { |path| self.class.support_path?(path.delete_prefix("#{@root}/")) && contained?(path) }
            .uniq.sort
      end

      def real_root
        @real_root ||= File.realpath(@root)
      end

      # @return [Hash{String => Array<String>}] 'module' / 'class' => qualified names
      def declarations(source)
        found = Hash.new { |hash, kind| hash[kind] = [] }
        each_declaration(source) { |kind, _name, qualified| found[kind] << qualified }
        found.transform_values(&:uniq)
      end

      def names_in(source, pattern)
        source.scan(pattern).map { |captures| captures.compact.first }.uniq
      end

      def includes_in(source)
        source.scan(CONFIG_INCLUDE).map do |scope, constant, rest|
          { module: constant.delete_prefix('::'), scope: scope, types: include_types(rest) }
        end.uniq
      end

      # `type: :feature`, `type: %i[feature system]`, `:type => [:feature]`.
      def include_types(rest)
        spec = rest[INCLUDE_TYPES, 1]
        return [] unless spec
        return [spec[/\A:(\w+)/, 1]] if spec.start_with?(':')

        spec[/\A(?:%i)?\[([^\]\n]*)\]/, 1].to_s.scan(/\w+/).uniq.sort
      end

      def matchers_in(source)
        return [] unless matcher_pattern

        source.scan(matcher_pattern).flatten.uniq
      end

      # A literal alternation of every defined matcher, longest first so a
      # name that prefixes another cannot shadow it.
      def matcher_pattern
        return @matcher_pattern if defined?(@matcher_pattern)

        names = index.fetch(:uses_matcher).keys.sort_by { |name| [-name.length, name] }
        @matcher_pattern = (/(?<![\w.:@$])(#{Regexp.union(names)})(?![\w?!])/ if names.any?)
      end

      # @return [Hash{Symbol => Hash{String => Array<String>}}] via => name => identifiers
      def index
        @index ||= begin
          built = { behaves_like: {}, includes_context: {}, includes_helper: {}, uses_matcher: {} }
          entries.each do |entry|
            add(built[:behaves_like], entry.shared_examples, entry)
            add(built[:includes_context], entry.shared_contexts, entry)
            add(built[:uses_matcher], entry.matchers, entry)
            add(built[:includes_helper], entry.helper_modules.flat_map { |name| name_suffixes(name) }, entry)
          end
          built
        end
      end

      def add(names_to_identifiers, names, entry)
        names.each { |name| (names_to_identifiers[name] ||= []) << entry.identifier }
      end

      def lookup_key(via, name)
        via == :includes_helper ? name.delete_prefix('::') : name
      end

      # `Support::BillingHelpers` answers to `BillingHelpers` too: an include
      # inside the namespace, or a spec that names it short, means that module.
      def name_suffixes(qualified)
        parts = qualified.split('::')
        Array.new(parts.size) { |start| parts[start..].join('::') }
      end

      # @return [Set<String>] qualified names of modules an include of +name+ can mean
      def module_matches(name)
        @module_names ||= entries.flat_map(&:helper_modules).uniq
        @module_names.select { |qualified| name_suffixes(qualified).include?(name) }.to_set
      end
    end
  end
end
