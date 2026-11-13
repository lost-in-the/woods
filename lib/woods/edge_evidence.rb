# frozen_string_literal: true

module Woods
  # How Woods knows a dependency edge: the evidence class behind a
  # `(source unit type, via)` pair, read from a catalog at read time. Nothing
  # is stored on the edge, so the graph file and its hash do not change.
  #
  # The classes, strongest first:
  #
  # - `reflected`: Rails (or the runtime it booted) reported the relationship
  #   itself. An association from reflection, a route in the route table, a
  #   loaded class's `superclass`, a foreign key from schema introspection.
  #   No source text was read to find the target.
  # - `verified`: Woods read source text and resolved what it names against
  #   live runtime tables. A constant the reference pass resolved, a `_path`
  #   helper matched against `named_routes`, a rendered component constant, a
  #   table name found in the live schema. This is wider than the `verified`
  #   confidence of a `metadata.references` span (docs/INDEX_LAYOUT.md), which
  #   means typed constant resolution only: every edge that span definition
  #   produces is `verified` here, and so are the route-helper, table and
  #   schema resolutions that never were spans.
  # - `static`: a source-text match that nothing checked against the runtime.
  #   A naming regex (`FooService.call`, `FooJob.perform_later`), a name
  #   inferred from a file or class name, a declaration parsed from a file,
  #   or a name resolved only against other files on disk.
  # - `unknown`: this build has no classification for the pair. It is never
  #   a default: an unlisted pair, an unlabelled edge and an unknown unit
  #   type all answer `unknown`.
  #
  # None of the classes means the code path executes. `reflected` says the
  # relationship is declared to the framework, not that a request reaches it.
  #
  # A pair that two mechanisms can produce takes the weaker class and is
  # listed in {MIXED}: the edge is at least that well supported. The class is
  # always decided by the edge's own source unit type, which for a reverse
  # traversal is not the unit asked about.
  #
  # @example
  #   Woods::EdgeEvidence.for('model', 'belongs_to')          # => "reflected"
  #   Woods::EdgeEvidence.for('controller', 'code_reference') # => "static"
  #   Woods::EdgeEvidence.mixed?('controller', 'code_reference') # => true
  module EdgeEvidence # rubocop:disable Metrics/ModuleLength -- the catalog is one table
    REFLECTED = 'reflected'
    VERIFIED = 'verified'
    STATIC = 'static'
    UNKNOWN = 'unknown'

    # The known classes, weakest first.
    ORDER = [STATIC, VERIFIED, REFLECTED].freeze
    # Every value {.for} can answer, strongest first.
    CLASSES = [REFLECTED, VERIFIED, STATIC, UNKNOWN].freeze

    # One line that defines the classes for a reader of tool text.
    LEGEND = 'reflected = reported by Rails; verified = source resolved against the running app; ' \
             'static = source-text match only.'

    # Unit types whose units the reference pass ({SourceReferences::Pass})
    # adds verified `code_reference`, `include` and `extend` edges to. Kept
    # equal to `SourceReferences::Registry::TYPES` by the spec.
    REFERENCE_PASS_TYPES = %w[
      model controller service poro lib concern job mailer component view_component graphql_type
      graphql_mutation graphql_resolver graphql_query serializer manager policy validator pundit_policy
      decorator action_cable_channel
    ].freeze

    s = STATIC
    v = VERIFIED
    r = REFLECTED

    # SharedDependencyScanner: name scans over source text.
    scans = { 'code_reference' => s, 'job_enqueue' => s, 'service_call' => s, 'reads_config' => s }.freeze
    scans_without_jobs = scans.except('job_enqueue').freeze
    # The reference pass's mixin edges on a type whose extractor publishes none.
    mixins = { 'include' => v, 'extend' => v }.freeze
    # RouteHelperResolver: a `_path`/`_url` helper found in the live named routes.
    navigation = { 'link_to' => v, 'form_action' => v }.freeze
    # HelperCatalog: a helper call, and a `helper_method` declaration.
    helpers = { 'helper_call' => s, 'helper_method' => v }.freeze
    # FrontendReferences: names in markup resolved against JavaScript files on disk.
    frontend = { 'alpine_data' => s, 'stimulus_controller' => s, 'custom_element' => s }.freeze
    # TestSupportCatalog: names resolved against the support files on disk.
    test_support = { 'behaves_like' => s, 'includes_context' => s, 'includes_helper' => s,
                     'uses_matcher' => s }.freeze
    # SuperclassDependency called with an identifier: the loaded class's
    # superclass, or the declared parent of a pending autoload.
    declared_parent = { 'inheritance' => v }.freeze
    component = { 'render' => v, 'slot' => v, 'data_dependency' => s, 'reads_config' => s, 'include' => s,
                  'extend' => v, 'code_reference' => v, 'inheritance' => r }
                .merge(navigation, helpers, frontend).freeze
    graphql = scans.merge(mixins, declared_parent, 'type_reference' => s, 'field_resolver' => s).freeze
    self_map_class = { 'inheritance' => s, 'include' => s, 'extend' => s, 'definition_of' => s }.freeze

    # Source unit type => via => evidence class. Every pair an extractor or a
    # later pass can emit; `spec/integration/booted_extraction_spec.rb` fails
    # on an extracted pair this does not list.
    CATALOG = {
      'model' => scans.merge(
        'belongs_to' => r, 'has_many' => r, 'has_one' => r, 'has_and_belongs_to_many' => r,
        'polymorphic_interface' => r, 'through_chain' => r, 'table' => r, 'inheritance' => r,
        'include' => v, 'extend' => v
      ),
      'controller' => scans.merge(helpers, 'include' => v, 'extend' => v, 'render' => v, 'redirect_to' => v,
                                           'action_source' => r, 'inheritance' => r),
      'mailer' => scans_without_jobs.merge(mixins, navigation, helpers, 'inheritance' => r),
      'service' => scans.merge(mixins, declared_parent, 'external_call' => s),
      'job' => scans.merge(mixins, declared_parent, 'external_call' => s),
      'lib' => scans.merge(mixins, declared_parent),
      'poro' => scans.merge(mixins, declared_parent),
      'concern' => scans.merge('include' => s, 'extend' => s),
      'component' => component.merge('call' => s),
      'view_component' => component,
      'graphql_type' => graphql,
      'graphql_mutation' => graphql,
      'graphql_resolver' => graphql,
      'graphql_query' => graphql,
      'serializer' => scans_without_jobs.merge(mixins, declared_parent, 'serialization' => s),
      'manager' => scans.merge(mixins, declared_parent, 'delegation' => s),
      'policy' => scans.merge(mixins, declared_parent, 'policy_evaluation' => s),
      'validator' => scans_without_jobs.merge(mixins, declared_parent, 'validation' => s),
      'pundit_policy' => scans_without_jobs.merge(mixins, declared_parent, 'authorization' => s),
      'decorator' => scans.merge(mixins, declared_parent, 'decoration' => s),
      'action_cable_channel' => scans.merge(mixins, 'inheritance' => r),
      'caching' => scans,
      'configuration' => scans.merge('configuration' => s, 'behavioral_profile' => r),
      'route' => { 'route_dispatch' => r, 'mount' => r, 'drawn_in' => r },
      'route_file' => { 'draw' => s },
      'engine' => { 'engine_route' => r },
      'database_table' => { 'foreign_key' => r },
      'database_view' => { 'view_source' => v, 'table_name' => v },
      'migration' => scans.merge('migrates' => v, 'table_name' => v, 'reference' => v),
      'external_consumer' => { 'reads_table' => v, 'writes_table' => v },
      'view_template' => { 'render' => s, 'view_render' => v }.merge(navigation, helpers, frontend),
      'graphql_operation' => { 'root_field' => v, 'type_reference' => v, 'fragment_spread' => s },
      'factory' => { 'factory_for' => s, 'factory_parent' => s, 'factory_association' => s },
      'rake_task' => scans.merge('task_invoke' => s, 'task_dependency' => s, 'method_call' => s),
      'scheduled_job' => { 'scheduled' => s },
      'event' => { 'published_by' => s, 'subscribed_by' => s },
      'state_machine' => { 'state_machine' => s, 'state_machine_callback' => s, 'job_enqueue' => s,
                           'service_call' => s },
      'package' => { 'package_dependency' => s },
      'js_module' => { 'import' => s },
      'test_mapping' => test_support.merge('test_coverage' => s, 'exercises_route' => v),
      'test_support' => test_support,
      'doc' => { 'documents' => s, 'doc_link' => s },
      # The static self-map (`woods:self_map`): parsed source, no runtime at all.
      'ruby_class' => self_map_class,
      'ruby_module' => self_map_class,
      'ruby_method' => { 'method_call' => s },
      'ruby_file' => { 'method_call' => s, 'require' => s, 'reference' => s, 'definition_of' => s }
    }.transform_values(&:freeze).freeze

    scan_or_pass = 'the extractor name scan (static) and the reference pass (verified) share the label'
    runtime_or_pass = 'the runtime module list (reflected) and the reference pass (verified) share the label'
    loaded_or_declared = 'a loaded class gives its superclass (reflected); a pending autoload gives the parent ' \
                         'its file declares, resolved against the constant tables (verified)'
    helper_owner = 'the context\'s `_helpers` names the defining module (verified); without one every module ' \
                   'whose source defines the name is a target (static)'
    graphql_path = 'a constant path the runtime resolves (verified) and one it cannot place (static) share the label'

    mixed = {}
    (REFERENCE_PASS_TYPES - %w[component view_component]).each { |type| mixed[[type, 'code_reference']] = scan_or_pass }
    %w[concern component view_component].each { |type| mixed[[type, 'include']] = scan_or_pass }
    mixed[%w[concern extend]] = scan_or_pass
    %w[model controller].each { |type| mixed[[type, 'include']] = runtime_or_pass }
    mixed[%w[model extend]] = runtime_or_pass
    CATALOG.each do |type, vias|
      mixed[[type, 'inheritance']] = loaded_or_declared if vias['inheritance'] == v
      mixed[[type, 'helper_call']] = helper_owner if vias.key?('helper_call')
    end
    %w[graphql_type graphql_mutation graphql_resolver graphql_query].each do |type|
      %w[type_reference field_resolver].each { |via| mixed[[type, via]] = graphql_path }
    end
    mixed[%w[view_template render]] =
      'a partial found on disk or through the owner\'s runtime prefixes, and an identifier guessed from the ' \
      'name, share the label (both static; the first is the better supported)'
    mixed[%w[rake_task task_dependency]] =
      'prerequisites the loaded Rake application reports (reflected) and literal ones read from source ' \
      '(static) share the label'

    # `[source type, via]` => why two mechanisms produce the pair. Its class
    # in {CATALOG} is the weaker of the two.
    MIXED = mixed.freeze

    class << self
      # @param source_type [String, Symbol, nil] the type of the unit the edge leaves
      # @param via [String, Symbol, nil] the edge's label
      # @return [String] one of {CLASSES}; `unknown` for a pair the catalog does not list
      def for(source_type, via)
        CATALOG.dig(source_type.to_s, via.to_s) || UNKNOWN
      end

      # @param source_type [String, Symbol, nil]
      # @param via [String, Symbol, nil]
      # @return [Boolean] whether two mechanisms produce the pair, so its
      #   class is a floor ("at least")
      def mixed?(source_type, via)
        MIXED.key?([source_type.to_s, via.to_s])
      end

      # The class of a chain: as weak as its weakest link, and `unknown` as
      # soon as one link is.
      #
      # @param classes [Array<String>]
      # @return [String, nil] nil for an empty list
      def weakest(classes)
        return nil if classes.empty?
        return UNKNOWN unless (classes - ORDER).empty?

        classes.min_by { |evidence| ORDER.index(evidence) }
      end

      # The class of one edge with several labels: one strong reason is
      # enough to believe it. `unknown` only when every label is.
      #
      # @param classes [Array<String>]
      # @return [String, nil] nil for an empty list
      def strongest(classes)
        return nil if classes.empty?

        (classes & ORDER).max_by { |evidence| ORDER.index(evidence) } || UNKNOWN
      end

      # The evidence of the edge between two units, from every `via` on it.
      #
      # @param source_type [String, Symbol, nil] the type of the unit the edge leaves
      # @param vias [Array<String, Symbol, nil>] every label on the edge
      # @return [Hash] `evidence:` (the strongest label's class; `unknown`
      #   for an unlabelled edge) and `mixed:` (true when every label of that
      #   class is a {MIXED} pair)
      def edge(source_type, vias)
        labels = Array(vias).compact
        evidence = strongest(labels.map { |via| self.for(source_type, via) }) || UNKNOWN
        decisive = labels.select { |via| self.for(source_type, via) == evidence }
        { evidence: evidence, mixed: decisive.any? && decisive.all? { |via| mixed?(source_type, via) } }
      end

      # The fields a hop carries for its edge.
      #
      # @param source_type [String, Symbol] type of the unit the edge leaves
      # @param vias [Array<String>] every via on the edge
      # @return [Hash] `evidence:`, plus `evidence_mixed: true` when that class is a floor
      def hop(source_type, vias)
        found = edge(source_type, vias)
        fields = { evidence: found[:evidence] }
        fields[:evidence_mixed] = true if found[:mixed]
        fields
      end

      # A path is as well supported as its weakest hop. The answer depends on
      # the set of hops, not their order: when one hop of the weakest class
      # is exactly that class, so is the path, and the path is a floor ("at
      # least") only when every hop of that class is one.
      #
      # @param hops [Array<Hash>] hops carrying `:evidence`, and
      #   `:evidence_mixed` when that class is a floor
      # @return [Hash] `evidence:`, plus `weakest_hop:` (counted from 1) unless
      #   every hop is reflected, and `evidence_mixed: true` when the path's
      #   class is a floor; empty for a path with no hops. `weakest_hop` is the
      #   first exact hop of the weakest class, or the first floor when there
      #   is none.
      def path(hops)
        weakest = weakest(hops.map { |hop| hop[:evidence] })
        return {} unless weakest
        return { evidence: weakest } if weakest == REFLECTED

        candidates = hops.each_index.select { |index| hops[index][:evidence] == weakest }
        exact = candidates.find { |index| !hops[index][:evidence_mixed] }
        return { evidence: weakest, weakest_hop: exact + 1 } if exact

        { evidence: weakest, weakest_hop: candidates.first + 1, evidence_mixed: true }
      end

      # @param evidence [String] one of {CLASSES}
      # @param mixed [Boolean] whether the class is a floor
      # @return [String] e.g. `static`, or `at least static`
      def label(evidence, mixed)
        mixed ? "at least #{evidence}" : evidence
      end

      # The catalog as the Markdown table docs/MCP_SERVERS.md carries: one
      # row per source type, its labels by class, a {MIXED} pair marked `*`.
      #
      # @return [String]
      def markdown_table
        rows = CATALOG.keys.sort.map do |type|
          cells = CLASSES.first(3).map do |evidence|
            vias = CATALOG.fetch(type).select { |_, value| value == evidence }.keys.sort
            vias.map { |via| "`#{via}`#{'*' if mixed?(type, via)}" }.join(', ')
          end
          "| `#{type}` | #{cells.join(' | ')} |"
        end
        ['| Source type | `reflected` | `verified` | `static` |', '|---|---|---|---|', *rows].join("\n")
      end
    end
  end
end
