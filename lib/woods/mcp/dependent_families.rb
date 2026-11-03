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

        # Add `family` (and `mapped_test` where it applies) to every row but
        # the root, and `dependent_counts` to the result. Call before paging.
        #
        # @param result [Hash] a found traversal result, with `nodes` keyed by identifier
        # @param vias [#call] `(source, target) -> Array<String>` recorded relationship labels
        # @param include_tests [Boolean] count mapped tests toward the headline
        # @return [Hash] the result
        def annotate(result, vias:, include_tests: include_tests?)
          return result if result[:found] == false

          nodes = result.fetch(:nodes)
          root = result[:root]
          counts = FAMILIES.to_h { |family| [family.to_sym, 0] }
          mapped = 0
          parents = parents_of(nodes)

          nodes.each do |identifier, entry|
            next if identifier == root

            family = family_for(entry[:types] || [entry[:type]])
            entry[:family] = family
            counts[family.to_sym] += 1
            next unless family == 'tests' && mapped_test?(identifier, entry, parents, vias)

            entry[:mapped_test] = MAPPED_TEST_RELATIONSHIP
            mapped += 1
          end

          result[:dependent_counts] = summary(counts, mapped, include_tests, result)
          result
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

        def summary(counts, mapped, include_tests, result)
          exact = !result[:partial]
          {
            scope: 'whole_traversal',
            exact: exact,
            bound: exact ? 'exact' : 'lower_bound',
            total: counts.values.sum,
            headline: counts[:code] + (include_tests ? mapped : 0),
            mapped_tests: mapped,
            reverse_includes_tests: include_tests,
            families: counts
          }
        end
      end
    end
  end
end
