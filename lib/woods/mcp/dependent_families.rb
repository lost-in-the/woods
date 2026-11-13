# frozen_string_literal: true

require 'set'

module Woods
  module MCP
    # Sorts the rows of a `dependents` traversal into families and counts them
    # over the whole walk, before any page is cut, so every renderer formats
    # the same numbers and none of them classifies on its own.
    #
    # Families are decided by published unit type, never by path: an agent
    # instruction file such as `AGENTS.md` is a `doc` unit and counts as docs
    # like any other documentation.
    #
    # Each family splits into detailed categories ({CATEGORIES}), also by
    # published type. The one exception is `doc`: a document is
    # `agent_instructions` when its identifier or one of its published alias
    # paths matches {AGENT_INSTRUCTION_FILES} or {AGENT_INSTRUCTION_DIRECTORIES},
    # and `documentation` otherwise. Its source text is never read.
    #
    # A **mapped test** is a `test_mapping` unit whose recorded edge to the
    # row it was reached from is `test_coverage`. That edge is a static
    # association between a spec and the code it names, not evidence that the
    # test ran. Mapped tests are always listed; `reverse_includes_tests` only
    # decides whether they count toward the headline.
    module DependentFamilies
      FAMILIES = %w[code tests schema docs other].freeze

      TESTS = %w[test_mapping test_support factory].freeze
      # The database and what reads it from outside, as DependencyGraph's
      # schema unit types are.
      SCHEMA = %w[database_table database_view migration external_consumer].freeze
      DOCS = %w[doc].freeze
      # Application code a change can reach: classes, templates and the code
      # sites a schedule entry, event or cache key is declared at.
      CODE = %w[
        model controller concern service job mailer serializer manager policy pundit_policy validator decorator
        component view_component view_template middleware action_cable_channel state_machine rake_task
        graphql_type graphql_mutation graphql_resolver graphql_query graphql_operation
        poro lib js_module ruby_class ruby_module ruby_method ruby_file
        scheduled_job event caching
      ].freeze
      # Published types that are deliberately `other`: routing, configuration,
      # packaging and framework source. A type in no list (a missing type, or
      # one a newer writer added) is `other` too.
      OTHER = %w[route route_file i18n configuration config_file engine package rails_source gem_source].freeze

      # Detailed categories, each inside exactly one family, so a family's
      # categories add up to it. No category shares a name with a family it
      # does not equal, so a `families:` selector value means one set only:
      # `other` is both, and the two are the same rows.
      CATEGORY_FAMILY = {
        'application_code' => 'code', 'rake_tasks' => 'code',
        'test_files' => 'tests', 'factories' => 'tests',
        'schema_objects' => 'schema', 'migrations' => 'schema',
        'documentation' => 'docs', 'agent_instructions' => 'docs',
        'other' => 'other'
      }.freeze
      CATEGORIES = CATEGORY_FAMILY.keys.freeze
      # The category of an identifier whose types share a family but not a
      # category, e.g. a model and a rake task under one name.
      GENERAL_CATEGORY = {
        'code' => 'application_code', 'tests' => 'test_files', 'schema' => 'schema_objects',
        'docs' => 'documentation', 'other' => 'other'
      }.freeze
      TYPE_CATEGORY = {
        'rake_task' => 'rake_tasks', 'factory' => 'factories', 'migration' => 'migrations'
      }.freeze
      # Every value a `families:` selector accepts: a family or a category.
      SELECTOR_VALUES = (FAMILIES + CATEGORIES).uniq.freeze

      # Agent instruction files by file name, in any directory: nested
      # `AGENTS.md` files are the convention's own scoping.
      AGENT_INSTRUCTION_FILES = %w[AGENTS.md CLAUDE.md CLAUDE.local.md GEMINI.md SKILL.md].freeze
      # Agent instruction files by the directory that holds them. Each entry
      # is a run of path segments; `.claude` matches at any depth.
      AGENT_INSTRUCTION_DIRECTORIES = [%w[.claude], %w[.github instructions]].freeze
      # Agent instruction files by their exact root-relative path.
      AGENT_INSTRUCTION_PATHS = %w[.github/copilot-instructions.md].freeze

      MAPPED_TEST_TYPE = 'test_mapping'
      MAPPED_TEST_VIA = 'test_coverage'
      # The recorded edge runs from the test to the code it names, the
      # opposite of the walk's direction.
      MAPPED_TEST_RELATIONSHIP = { via: MAPPED_TEST_VIA, direction: 'test_to_subject' }.freeze

      ENV_KEY = 'WOODS_REVERSE_INCLUDES_TESTS'
      TRUE_VALUES = %w[1 true yes on].freeze
      FALSE_VALUES = %w[0 false no off].freeze

      class << self
        # Whether mapped tests count toward the `dependents` headline. An MCP
        # server started without the host initializer takes the switch from
        # `WOODS_REVERSE_INCLUDES_TESTS`, which wins over the configuration.
        # Read only at query time: extraction never consults it.
        #
        # @return [Boolean]
        def include_tests?
          override = env_override
          return override unless override.nil?

          config = Woods.configuration if Woods.respond_to?(:configuration)
          config.respond_to?(:reverse_includes_tests) && config.reverse_includes_tests == true
        end

        # The family of one traversal row.
        #
        # @param types [Array<String, nil>] every published type of the identifier
        # @return [String] one of {FAMILIES}; `other` when the types disagree or are unknown
        def family_for(types)
          families = Array(types).map { |type| type_family(type) }.uniq
          families.size == 1 ? families.first : 'other'
        end

        # The detailed category of one traversal row.
        #
        # @param types [Array<String, nil>] every published type of the identifier
        # @param paths [Array<String>] the identifier and its published alias
        #   paths, root-relative; read only for `doc` units
        # @return [String] one of {CATEGORIES}, inside {#family_for}'s family
        def category_for(types, paths: [])
          types = Array(types)
          family = family_for(types)
          return 'other' if family == 'other'

          categories = types.map { |type| type_category(type, paths) }.uniq
          categories.size == 1 ? categories.first : GENERAL_CATEGORY.fetch(family)
        end

        # Is a document an agent instruction file? Decided by path alone, from
        # the identifier and the alias paths the graph publishes for it. An
        # absolute path (outside the application root) never matches.
        #
        # @param paths [Array<String>] root-relative paths naming one document
        # @return [Boolean]
        def agent_instructions?(paths)
          Array(paths).any? do |path|
            path = path.to_s
            next false if path.empty? || path.start_with?('/')

            segments = path.split('/')
            AGENT_INSTRUCTION_PATHS.include?(path) || AGENT_INSTRUCTION_FILES.include?(segments.last) ||
              AGENT_INSTRUCTION_DIRECTORIES.any? { |run| directory_run?(segments[0...-1], run) }
          end
        end

        # The categories a `families:` selector names, in {CATEGORIES} order.
        #
        # @param values [Array<String>] family or category names; duplicates collapse
        # @return [Hash] `requested:` the distinct values in {SELECTOR_VALUES}
        #   order, `categories:` the categories they cover
        # @raise [ArgumentError] when the list is empty or names an unknown value
        def resolve_selector(values)
          values = Array(values)
          if values.empty?
            raise ArgumentError, 'families must name at least one family or category; omit it to list every row'
          end

          unknown = values.reject { |value| SELECTOR_VALUES.include?(value) }
          unless unknown.empty?
            raise ArgumentError, "unknown families value#{'s' if unknown.size > 1}: " \
                                 "#{unknown.map(&:inspect).uniq.join(', ')}; " \
                                 "expected any of #{SELECTOR_VALUES.join(', ')}"
          end

          requested = SELECTOR_VALUES.select { |value| values.include?(value) }
          covered = CATEGORIES.select do |category|
            requested.include?(category) || requested.include?(CATEGORY_FAMILY.fetch(category))
          end
          { requested: requested, categories: covered }
        end

        # Add `family`, `category` (and `mapped_test` where it applies) to
        # every row but the root, and `dependent_counts` to the result. Call
        # before paging.
        #
        # @param result [Hash] a found traversal result, with `nodes` keyed by identifier
        # @param vias [#call] `(source, target) -> Array<String>` recorded relationship labels
        # @param paths [#call] `(identifier) -> Array<String>` the identifier's
        #   published root-relative paths, aliases included
        # @param include_tests [Boolean] count mapped tests toward the headline
        # @return [Hash] the result
        def annotate(result, vias:, paths: ->(identifier) { [identifier] }, include_tests: include_tests?)
          return result if result[:found] == false

          nodes = result.fetch(:nodes)
          root = result[:root]
          parents = parents_of(nodes)

          nodes.each do |identifier, entry|
            next if identifier == root

            types = entry[:types] || [entry[:type]]
            entry[:family] = family_for(types)
            entry[:category] = category_for(types, paths: types.include?('doc') ? paths.call(identifier) : [])
            next unless entry[:family] == 'tests' && mapped_test?(identifier, entry, parents, vias)

            entry[:mapped_test] = MAPPED_TEST_RELATIONSHIP
          end

          result[:dependent_counts] = summary(nodes.reject { |identifier, _| identifier == root }.values,
                                              include_tests, result)
          code_first!(result, root)
          result
        end

        # List code ahead of tests, schema, documentation and the rest, at
        # each depth and under each row. The walk reaches neighbours in
        # identifier order, which put agent-instruction and documentation
        # files (`.claude/...`, `AGENTS.md`) at the top of a model's
        # dependents, and the first page of 50 rows could hold no code at
        # all. Order within a family is the walk's.
        #
        # @param result [Hash] a classified traversal result
        # @param root [String]
        # @return [void]
        def code_first!(result, root)
          nodes = result.fetch(:nodes)
          rank = lambda do |identifier|
            identifier == root ? -1 : FAMILIES.index(nodes.dig(identifier, :family)) || FAMILIES.size
          end
          nodes.each_value { |entry| entry[:deps] = entry[:deps].sort_by.with_index { |dep, at| [rank.call(dep), at] } }
          ordered = nodes.sort_by.with_index { |(identifier, entry), at| [entry[:depth], rank.call(identifier), at] }
          result[:nodes] = ordered.to_h
        end

        # Counts over classified rows, in the `dependent_counts` shape.
        #
        # @param entries [Array<Hash>] rows {#annotate} classified
        # @param include_tests [Boolean]
        # @param result [Hash] the traversal result, for its exactness
        # @return [Hash]
        def summary(entries, include_tests, result)
          families = FAMILIES.to_h { |family| [family.to_sym, 0] }
          categories = CATEGORIES.to_h { |category| [category.to_sym, 0] }
          entries.each do |entry|
            families[entry.fetch(:family).to_sym] += 1
            categories[entry.fetch(:category).to_sym] += 1
          end
          mapped = entries.count { |entry| entry.key?(:mapped_test) }
          exact = !result[:partial]
          {
            scope: 'whole_traversal',
            exact: exact,
            bound: exact ? 'exact' : 'lower_bound',
            total: entries.size,
            headline: families[:code] + (include_tests ? mapped : 0),
            mapped_tests: mapped,
            reverse_includes_tests: include_tests,
            families: families,
            categories: categories
          }
        end

        private

        # @return [Boolean, nil] the environment's answer; nil when unset,
        #   empty or unrecognized (which warns and leaves the configuration in charge)
        def env_override
          raw = ENV.fetch(ENV_KEY, nil)
          value = raw.to_s.strip.downcase
          return if value.empty?
          return true if TRUE_VALUES.include?(value)
          return false if FALSE_VALUES.include?(value)

          warn "[woods] Ignoring #{ENV_KEY}=#{raw.inspect}: expected one of " \
               "#{(TRUE_VALUES + FALSE_VALUES).join(', ')}; using config.reverse_includes_tests."
          nil
        end

        def type_category(type, paths)
          return TYPE_CATEGORY.fetch(type) if TYPE_CATEGORY.key?(type)
          return agent_instructions?(paths) ? 'agent_instructions' : 'documentation' if DOCS.include?(type)

          GENERAL_CATEGORY.fetch(type_family(type))
        end

        def directory_run?(directories, run)
          (0..(directories.size - run.size)).any? { |start| directories[start, run.size] == run }
        end

        def type_family(type)
          return 'code' if CODE.include?(type)
          return 'tests' if TESTS.include?(type)
          return 'schema' if SCHEMA.include?(type)
          return 'docs' if DOCS.include?(type)

          'other'
        end

        # identifier => rows whose `deps` list it, i.e. the rows it was reached from.
        def parents_of(nodes)
          parents = Hash.new { |hash, key| hash[key] = [] }
          nodes.each { |identifier, entry| Array(entry[:deps]).each { |dep| parents[dep] << identifier } }
          parents
        end

        def mapped_test?(identifier, entry, parents, vias)
          return false unless (entry[:types] || [entry[:type]]).include?(MAPPED_TEST_TYPE)

          parents.fetch(identifier, []).any? { |parent| vias.call(identifier, parent).include?(MAPPED_TEST_VIA) }
        end
      end
    end
  end
end
