# frozen_string_literal: true

# Woods - Rails Codebase Indexing and Retrieval
#
# A system for extracting, indexing, and retrieving context from Rails codebases
# to enable AI-assisted development, debugging, and analytics.
#
# ## Quick Start
#
#   # Extract codebase
#   Woods.extract!
#
#   # Or via rake
#   bundle exec rake woods:extract
#
# ## Configuration
#
#   Woods.configure do |config|
#     config.output_dir = Rails.root.join("tmp/woods")
#     config.max_context_tokens = 8000
#     config.include_framework_sources = true
#   end
#
require 'digest'
require 'json'
require_relative 'woods/version'
require_relative 'woods/deprecation'
# Configuration's `component_paths` default lives with the discovery it feeds.
require_relative 'woods/extractors/component_discovery'
require_relative 'woods/graphql_document_paths'
# Configuration validates declared external table consumers at assignment.
require_relative 'woods/extractors/external_consumer_declarations'
# Configuration validates `rake_task_paths` at assignment.
require_relative 'woods/extractors/rake_task_paths'
# Configuration defaults the cycle caps to the analyzer's own constants.
require_relative 'woods/graph_analyzer'
# Configuration's `source_reference_callers` default lives with the pass it feeds.
require_relative 'woods/source_references/caller_policy'
require_relative 'woods/javascript_paths'

module Woods
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ExtractionError < Error; end
  # An incremental run refused because the extraction-shaping configuration
  # differs from the baseline's. Only a full extraction resolves it.
  class ExtractionConfigChanged < ExtractionError; end
  class SessionTracerError < Error; end

  CONFIG_MUTEX = Mutex.new

  # Console MCP secure defaults — Layer 3 column-name redaction.
  #
  # Columns named here are replaced with `[REDACTED]` in every MCP tool
  # response. This list targets credential columns that appear with the
  # same names across Devise, Doorkeeper, Rodauth, has_secure_password,
  # devise-two-factor, OAuth integrations, and hand-rolled auth code.
  #
  # Intentionally omitted because they cause over-redaction in apps that
  # use them for non-secret purposes:
  #   - `key` — ActiveStorage blob keys, EAV key columns, translation keys
  #   - `name` — universal non-secret identifier
  #   - PII columns (`ssn`, `tax_id`, `dob`) — org-specific compliance concern
  #
  # Host apps extend this by reassigning `console_redacted_columns` to
  # `Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS + %w[extra_column]`, or
  # override entirely to remove a default.
  DEFAULT_CONSOLE_REDACTED_COLUMNS = %w[
    password
    password_digest
    password_salt
    encrypted_password
    crypted_password
    salt
    otp_secret
    encrypted_otp_secret
    two_factor_secret
    backup_codes
    consumed_timestep
    reset_password_token
    confirmation_token
    unlock_token
    remember_token
    invitation_token
    access_token
    refresh_token
    auth_token
    api_token
    api_key
    bearer_token
    client_secret
    webhook_secret
    signing_secret
    session_secret
    private_key
    encrypted_private_key
    key_hash
    token
    secret
  ].freeze

  # Console MCP secure defaults — Layer 1 table-level blocking.
  #
  # Tables named here are rejected outright before any SQL reaches the
  # database. This list targets authentication and credential storage
  # tables that carry secrets or session state across all major auth
  # stacks (Devise, Doorkeeper, Rodauth, has_secure_password, Sorcery,
  # OmniAuth, and hand-rolled token systems).
  #
  # Intentionally omitted to avoid over-blocking benign apps:
  #   - `users` / `accounts` — many apps expose safe columns from these
  #     tables and operators should decide explicitly.
  #   - PII-heavy but auth-unrelated tables (`payments`, `addresses`) —
  #     org-specific compliance concern, not a universal default.
  #
  # To keep the defaults and add more tables:
  #   Woods.configure { |c| c.console_blocked_tables =
  #     Woods::DEFAULT_CONSOLE_BLOCKED_TABLES + %w[extra_table] }
  #
  # To replace the defaults entirely (including removing entries):
  #   Woods.configure { |c| c.console_blocked_tables = %w[only_this] }
  #
  # To disable Layer 1 (gate becomes inactive; other layers still apply):
  #   Woods.configure { |c| c.console_blocked_tables = [] }
  DEFAULT_CONSOLE_BLOCKED_TABLES = %w[
    sessions
    api_keys
    credentials
    oauth_applications
    oauth_access_tokens
    oauth_refresh_tokens
    identities
    active_storage_blobs
  ].freeze

  # ════════════════════════════════════════════════════════════════════════
  # Configuration
  # ════════════════════════════════════════════════════════════════════════

  class Configuration # rubocop:disable Metrics/ClassLength
    # The set every full extraction always runs, regardless of `extractors=`.
    # The deprecated {#extractors=} knob does not gate extraction.
    DEFAULT_EXTRACTORS = %i[models controllers services components view_components jobs mailers graphql
                            serializers managers policies validators rails_source].freeze

    # Settings that decide which units and edges an extraction publishes, and
    # that an incremental run cannot reconcile on its own. Each published
    # generation records a digest of them; incremental extraction refuses to
    # build on a generation whose digests differ. See {#extraction_fingerprint}.
    EXTRACTION_KEYS = %i[include_framework_sources extract_navigation_edges component_paths
                         event_patterns event_paths unclaimed_ruby_paths graphql_document_paths
                         config_file_paths config_file_values settings_readers
                         external_table_consumers external_table_consumers_path
                         test_support_paths test_subdomain_helpers rake_task_paths javascript_paths
                         documentation_paths documentation_exclude method_effects_limit
                         git_recent_commits].freeze

    # Markdown the documentation extractor indexes as `doc` units, as
    # root-relative globs. See {#documentation_paths=}.
    DEFAULT_DOCUMENTATION_PATHS = %w[
      README.md docs/**/*.md doc/**/*.md CLAUDE.md AGENTS.md
      .claude/rules/**/*.md .claude/skills/**/*.md .github/**/*.md
    ].freeze

    # Changelogs, vendored trees and generated API documentation.
    DEFAULT_DOCUMENTATION_EXCLUDE = %w[
      **/CHANGELOG*.md **/node_modules/**/* **/vendor/**/* doc/api/**/* docs/api/**/*
    ].freeze

    attr_accessor :include_framework_sources, :gem_configs,
                  :vector_store, :metadata_store, :graph_store, :embedding_provider,
                  :vector_store_options, :metadata_store_options, :embedding_options,
                  :concurrent_extraction, :extract_navigation_edges, :enable_snapshots,
                  :session_tracer_enabled, :session_tracer_allow_production,
                  :session_store, :session_id_proc, :session_exclude_paths,
                  :console_mcp_enabled, :console_mcp_http_enabled, :console_mcp_path, :console_mcp_token,
                  :console_mcp_allowed_origins,
                  :console_redacted_columns,
                  :console_redacted_key_values, :console_embedded_read_tools,
                  :console_sql_default_limit, :console_sql_max_limit,
                  :console_blocked_tables, :console_disabled_scanner_patterns,
                  :console_credential_defense_enabled,
                  :console_credential_rotation_warning, :console_unsafe_eval_enabled,
                  :console_unsafe_eval_confirmation, :console_unsafe_eval_audit_log_path,
                  :notion_api_token, :notion_database_ids, :notion_export_column_defaults,
                  :unblocked_api_token, :unblocked_collection_id, :unblocked_repo_url,
                  :cache_store, :cache_options,
                  :dump_retention_count, :component_paths
    attr_reader :precompute_flows,
                :retrieval_mode, :embedding_model, :max_context_tokens, :similarity_threshold, :extractors,
                :pretty_json,
                :context_format, :cache_enabled, :volatile_dependency_ratio, :volatile_dependency_limit_per_target,
                :graph_cycle_limit, :graph_cycle_max_length, :method_effects_limit,
                :incremental_blast_radius_depth, :durable_payload_writes, :event_patterns, :event_paths,
                :unclaimed_ruby_paths, :graphql_document_paths, :config_file_paths, :config_file_values,
                :settings_readers, :external_table_consumers, :external_table_consumers_path,
                :test_support_paths, :test_subdomain_helpers, :source_reference_callers, :rake_task_paths,
                :javascript_paths, :documentation_paths, :documentation_exclude, :retrieve_documentation,
                :git_recent_commits, :git_commit_table_days, :git_commit_table_limit,
                :git_commit_table_files_limit, :git_commit_table_line_stats, :git_commit_table_hunk_budget

    def initialize # rubocop:disable Metrics/MethodLength
      @output_dir = nil # Resolved lazily; Rails.root is nil at require time
      @retrieval_mode = :semantic
      @embedding_model = 'text-embedding-3-small'
      @embedding_model_explicit = false
      @max_context_tokens = 8000
      @similarity_threshold = 0.7
      @include_framework_sources = true
      @gem_configs = {}
      @extractors = DEFAULT_EXTRACTORS.dup
      @pretty_json = true
      @concurrent_extraction = false
      @precompute_flows = false
      @extract_navigation_edges = true
      @enable_snapshots = false
      @context_format = :markdown
      @session_tracer_enabled = false
      @session_tracer_allow_production = false
      @session_store = nil
      @session_id_proc = nil
      @session_exclude_paths = []
      @console_mcp_enabled = false
      # Preserve existing HTTP setups. Stdio-only hosts explicitly disable
      # HTTP while leaving the Console master switch enabled.
      @console_mcp_http_enabled = true
      @console_mcp_path = '/mcp/console'
      # Accept token from config or env var. Nil by default — the railtie
      # rejects production boot when HTTP Console is enabled without a real
      # token, and warns in non-production. Stdio does not use this token.
      @console_mcp_token = ENV.fetch('WOODS_CONSOLE_MCP_TOKEN', nil)
      # Origins allowed to reach the embedded console MCP. Loopback only
      # by default; override in host initializers for tunneled or internal
      # dashboard access.
      @console_mcp_allowed_origins = %w[
        http://localhost
        http://127.0.0.1
        http://[::1]
      ]
      @console_redacted_columns = DEFAULT_CONSOLE_REDACTED_COLUMNS.dup
      @console_redacted_key_values = []
      @console_embedded_read_tools = false
      @console_sql_default_limit = 100
      @console_sql_max_limit = 1_000
      @console_blocked_tables = DEFAULT_CONSOLE_BLOCKED_TABLES.dup
      @console_disabled_scanner_patterns = []
      @console_credential_defense_enabled = true
      @console_credential_rotation_warning = true
      @console_unsafe_eval_enabled = nil # nil = fall back to env WOODS_CONSOLE_UNSAFE_EVAL
      # Required collaborators when the opt-in is on. Both default to nil;
      # the server refuses to boot with the opt-in set unless the host has
      # wired them (fail-closed — see Server.build_embedded).
      @console_unsafe_eval_confirmation = nil
      @console_unsafe_eval_audit_log_path = nil
      @notion_api_token = nil
      @notion_database_ids = {}
      @notion_export_column_defaults = false
      @unblocked_api_token = nil
      @unblocked_collection_id = nil
      @unblocked_repo_url = nil
      @cache_enabled = false
      @cache_store = nil      # :redis, :solid_cache, :memory, or a CacheStore instance
      @cache_options = {}     # { redis: client, cache: store, ttl: { embeddings: 86400, ... } }
      @dump_retention_count = 3
      @volatile_dependency_ratio = 3.0
      @volatile_dependency_limit_per_target = nil
      @graph_cycle_limit = GraphAnalyzer::DEFAULT_CYCLE_LIMIT
      @graph_cycle_max_length = GraphAnalyzer::DEFAULT_CYCLE_MAX_LENGTH
      @method_effects_limit = 50
      # Commit records each unit keeps in `metadata.git.recent_commits`.
      @git_recent_commits = 5
      # Bounds of the generation's commit table, git_commits.json. See the setters.
      @git_commit_table_days = 365
      @git_commit_table_limit = 5_000
      @git_commit_table_files_limit = 100
      @git_commit_table_line_stats = true
      @git_commit_table_hunk_budget = 50_000
      # nil = the unbounded transitive closure. See the setter for why the
      # default is not a small number.
      @incremental_blast_radius_depth = nil
      # false = payload files are written without a per-file fsync and the
      # whole payload is flushed once before `generation.json` is written.
      # See the setter.
      @durable_payload_writes = false
      # Directories the component extractors walk before reading `descendants`,
      # relative to Rails.root. See Extractors::ComponentDiscovery.
      @component_paths = Extractors::ComponentDiscovery::DEFAULT_COMPONENT_PATHS.dup
      # Application event wrappers EventExtractor scans for, on top of its
      # built-in ActiveSupport::Notifications and Wisper patterns.
      @event_patterns = [].freeze
      # Roots EventExtractor scans, relative to Rails.root. See the setter.
      @event_paths = %w[app].freeze
      # Globs PoroExtractor sweeps for Ruby no other extractor claims.
      @unclaimed_ruby_paths = ['app/**/*.rb'].freeze
      # Globs GraphQLOperationExtractor scans for client operation documents.
      @graphql_document_paths = GraphQLDocumentPaths::DEFAULT
      # Globs ConfigFileExtractor indexes as config_file units. See the setter.
      @config_file_paths = %w[config/*.yml config/**/*.yml app/data/**/*.yml].freeze
      @config_file_values = false
      # Settings constants whose reads link to a config_file unit. See the setter.
      @settings_readers = [].freeze
      # Other applications that read this database's tables. See the setters.
      @external_table_consumers = {}.freeze
      @external_table_consumers_path = nil
      # Globs TestSupportExtractor indexes as test_support units.
      @test_support_paths = %w[spec/support/**/*.rb spec/*_helper.rb spec/lib/**/*.rb
                               test/support/**/*.rb test/*_helper.rb test/lib/**/*.rb].freeze
      # Test helpers whose literal argument names the subdomain a test runs on.
      @test_subdomain_helpers = %w[with_subdomain use_subdomain using_subdomain set_subdomain
                                   switch_to_subdomain on_subdomain].freeze
      # Which unit types publish verified code_reference edges, and to which
      # target types. See the setter.
      @source_reference_callers = SourceReferences::CallerPolicy.normalize(nil)
      # Files RakeTaskExtractor reads. See Extractors::RakeTaskPaths.
      @rake_task_paths = Extractors::RakeTaskPaths::DEFAULT_PATHS
      # Globs JsModuleExtractor scans for JavaScript/TypeScript modules.
      @javascript_paths = JavascriptPaths::DEFAULT_GLOBS
      @documentation_paths = DEFAULT_DOCUMENTATION_PATHS
      @documentation_exclude = DEFAULT_DOCUMENTATION_EXCLUDE
      # Whether retrieval returns `doc` units unless a caller filters by type.
      @retrieve_documentation = true
    end

    def embedding_model=(value)
      @embedding_model = value
      @embedding_model_explicit = true
    end

    def embedding_model_explicit?
      @embedding_model_explicit
    end

    # @return [Pathname, String] Output directory, defaulting to Rails.root/tmp/woods
    def output_dir
      @output_dir ||= defined?(Rails) && Rails.root ? Rails.root.join('tmp/woods') : 'tmp/woods'
    end

    # @param value [Object] Must respond to #to_s
    # @raise [ConfigurationError] if value is nil
    def output_dir=(value)
      raise ConfigurationError, 'output_dir cannot be nil' if value.nil?

      @output_dir = value
    end

    # @param value [Integer] Must be a positive Integer
    # @raise [ConfigurationError] if value is not a positive Integer
    def max_context_tokens=(value)
      unless value.is_a?(Integer) && value.positive?
        raise ConfigurationError, "max_context_tokens must be a positive Integer, got #{value.inspect}"
      end

      @max_context_tokens = value
    end

    # Deprecated compatibility setting; retrieval never applies this cutoff.
    # @param value [Numeric] Must be between 0.0 and 1.0 inclusive
    # @raise [ConfigurationError] if value is out of range or not numeric
    def similarity_threshold=(value)
      raise ConfigurationError, "similarity_threshold must be Numeric, got #{value.inspect}" unless value.is_a?(Numeric)

      float_val = value.to_f
      unless float_val.between?(0.0, 1.0)
        raise ConfigurationError, "similarity_threshold must be between 0.0 and 1.0, got #{value.inspect}"
      end

      warn '[woods] similarity_threshold is deprecated and does not filter retrieval results; ' \
           'use explicit types/scopes and inspect returned ranking evidence instead.'
      @similarity_threshold = float_val
    end

    # Deprecated and inert: extraction always runs every registered
    # extractor, and nothing in the extraction path reads this array. Reads
    # and writes keep working until the option is removed in Woods 3.0.
    # An explicit assignment (default list included) warns once per process;
    # the default set at construction never does.
    #
    # @param value [Array<Symbol>] List of extractor names
    # @raise [ConfigurationError] if value is not an Array of Symbols
    def extractors=(value)
      unless value.is_a?(Array) && value.all?(Symbol)
        raise ConfigurationError, "extractors must be an Array of Symbols, got #{value.inspect}"
      end

      Deprecation.warn_once(
        :config_extractors,
        'config.extractors is deprecated and has no effect: every extractor always runs. ' \
        'Remove the assignment from your Woods initializer; the option will be removed in Woods 3.0.'
      )
      @extractors = value
    end

    # Force an fsync on every payload file as it is written, on top of the
    # single flush the publish already performs.
    #
    # Off by default, and off is not a weaker guarantee. Readers resolve only
    # through `generation.json`; a payload file has no reader until that
    # pointer names it, and {Woods::Extractor#sync_payload} makes the whole
    # payload durable before the pointer is written. Turning this on buys
    # exactly one thing: an individual payload file being durable before the
    # pointer exists.
    #
    # It costs a lot for it. Two forced flushes per file, 8.9ms each on btrfs:
    # 8000 units is 71s of writing against 1s.
    #
    # Turning it on cannot disable the publish flush. That flush *is* the
    # durability contract, so it has no opt-out.
    #
    # @param value [Boolean]
    # @raise [Woods::ConfigurationError] when value is not a boolean
    def durable_payload_writes=(value)
      validate_boolean!(:durable_payload_writes, value)
      @durable_payload_writes = value
    end

    # @param value [Boolean] Must be true or false
    # @raise [ConfigurationError] if value is not a boolean
    def pretty_json=(value)
      validate_boolean!(:pretty_json, value)
      @pretty_json = value
    end

    # @param value [Symbol, String] semantic (default) or lexical
    # @raise [ConfigurationError] if value is not a supported retrieval mode
    def retrieval_mode=(value)
      unless %w[semantic lexical].include?(value.to_s)
        raise ConfigurationError, "retrieval_mode must be semantic or lexical, got #{value.inspect}"
      end

      @retrieval_mode = value.to_sym
    end

    # Request-flow precomputation (W-14, woods#764).
    #
    # * +false+ (default): no flow family is written, and an existing one is withdrawn.
    # * +true+: every controller action's flow is assembled; any failure aborts the
    #   run before the generation is published (fail closed).
    # * +:best_effort+: every flow that assembles is published; an action that does
    #   not is left out of +flows/flow_index.json+ and recorded under
    #   +flow_failures+ in +skipped_files.json+ (reason +flow_assembly_error+).
    #
    # @param value [Boolean, Symbol, String] +false+, +true+ or +:best_effort+ (also +"best_effort"+)
    # @raise [ConfigurationError] for any other value
    def precompute_flows=(value)
      @precompute_flows = case value
                          when true, false, nil then value || false
                          when :best_effort, 'best_effort' then :best_effort
                          else
                            raise ConfigurationError,
                                  "precompute_flows must be true, false or :best_effort, got #{value.inspect}"
                          end
    end

    # @return [Boolean] whether flow precomputation publishes the flows it can and records the rest
    def best_effort_flows?
      @precompute_flows == :best_effort
    end

    # @param value [Symbol] Must be one of :claude, :markdown, :plain, :json
    # @raise [ConfigurationError] if value is not a valid format
    def context_format=(value)
      valid = %i[claude markdown plain json]
      unless valid.include?(value)
        raise ConfigurationError, "context_format must be one of #{valid.inspect}, got #{value.inspect}"
      end

      @context_format = value
    end

    # @param value [Boolean] Enable or disable the cache layer
    # @raise [ConfigurationError] if value is not a boolean
    def cache_enabled=(value)
      validate_boolean!(:cache_enabled, value)
      @cache_enabled = value
    end

    # Commit-count ratio above which {Woods::GraphAnalyzer#volatile_dependencies}
    # reports an edge. Stored as a Float.
    #
    # @param value [Numeric] must be greater than 1
    # @raise [ConfigurationError] otherwise
    def volatile_dependency_ratio=(value)
      unless value.is_a?(Numeric) && value > 1
        raise ConfigurationError, "volatile_dependency_ratio must be a number greater than 1, got #{value.inspect}"
      end

      @volatile_dependency_ratio = value.to_f
    end

    # Maximum volatile report edges per typed dependency, before the global
    # report limit. `nil` preserves the unlimited default.
    #
    # @param value [Integer, nil] must be a positive Integer, or nil
    # @raise [ConfigurationError] otherwise
    def volatile_dependency_limit_per_target=(value)
      @volatile_dependency_limit_per_target = validate_optional_positive_integer!(:volatile_dependency_limit_per_target,
                                                                                  value)
    end

    # How many distinct cycles {Woods::GraphAnalyzer#cycles} enumerates before
    # it stops. `nil` removes the cap and restores exhaustive enumeration.
    #
    # @param value [Integer, nil] must be a positive Integer, or nil
    # @raise [ConfigurationError] otherwise
    def graph_cycle_limit=(value)
      @graph_cycle_limit = validate_optional_positive_integer!(:graph_cycle_limit, value)
    end

    # The longest cycle {Woods::GraphAnalyzer#cycles} records, in distinct
    # nodes. `nil` removes the cap.
    #
    # @param value [Integer, nil] must be a positive Integer, or nil
    # @raise [ConfigurationError] otherwise
    def graph_cycle_max_length=(value)
      @graph_cycle_max_length = validate_optional_positive_integer!(:graph_cycle_max_length, value)
    end

    # How many public methods one unit records in `metadata.method_effects`
    # before the map is cut off and `method_effects_truncated` is set. `nil`
    # removes the cap.
    #
    # @param value [Integer, nil] must be a positive Integer, or nil
    # @raise [ConfigurationError] otherwise
    def method_effects_limit=(value)
      @method_effects_limit = validate_optional_positive_integer!(:method_effects_limit, value)
    end

    # How many commit records each unit keeps in `metadata.git.recent_commits`
    # (default 5). `commit_count` and `contributors` always cover the whole
    # 365-day window; only the list of records is bounded.
    #
    # The value is part of the generation's configuration fingerprint: after
    # changing it, incremental extraction refuses until one full extraction.
    #
    # @param value [Integer] must be a positive Integer
    # @raise [ConfigurationError] otherwise
    def git_recent_commits=(value)
      @git_recent_commits = validate_positive_integer!(:git_recent_commits, value)
    end

    # How many days before the run's UTC date the commit table
    # (`git_commits.json`) reaches back (default 365, the window of
    # `metadata.git`).
    #
    # @param value [Integer] must be a positive Integer
    # @raise [ConfigurationError] otherwise
    def git_commit_table_days=(value)
      @git_commit_table_days = validate_positive_integer!(:git_commit_table_days, value)
    end

    # The most commits the commit table publishes (default 5000). The newest
    # are kept; when older commits in the window are dropped the table says
    # `truncated: true`.
    #
    # @param value [Integer] must be a positive Integer
    # @raise [ConfigurationError] otherwise
    def git_commit_table_limit=(value)
      @git_commit_table_limit = validate_positive_integer!(:git_commit_table_limit, value)
    end

    # The most files the commit table lists for one commit (default 100); the
    # rest are counted in the commit's `files_omitted`. The `paths` table is
    # never bounded by it.
    #
    # @param value [Integer] must be a positive Integer
    # @raise [ConfigurationError] otherwise
    def git_commit_table_files_limit=(value)
      @git_commit_table_files_limit = validate_positive_integer!(:git_commit_table_files_limit, value)
    end

    # Whether the commit table records each listed file's line counts and
    # hunks (default true, woods#804). They come from a second, `-U0` patch
    # walk over only the table's commits, which costs far more than the
    # table's own walk on a large history; false leaves the fields out.
    #
    # @param value [Boolean]
    # @raise [ConfigurationError] unless true or false
    def git_commit_table_line_stats=(value)
      unless [true, false].include?(value)
        raise ConfigurationError, "git_commit_table_line_stats must be true or false, got #{value.inspect}"
      end

      @git_commit_table_line_stats = value
    end

    # The most hunks the commit table keeps across all its commits (default
    # 50000), newest commits first; files past it keep their line counts and
    # say `hunks_truncated`. One file keeps at most 100.
    #
    # @param value [Integer] must be a positive Integer
    # @raise [ConfigurationError] otherwise
    def git_commit_table_hunk_budget=(value)
      @git_commit_table_hunk_budget = validate_positive_integer!(:git_commit_table_hunk_budget, value)
    end

    # How many reverse hops an incremental run walks from a changed file
    # before it stops re-extracting dependents. `nil` (the default) keeps the
    # unbounded transitive closure.
    #
    # A unit's extracted content is mostly a function of its own source and
    # its own reflection, so on most graphs a small cap re-extracts the same
    # bytes far faster. It is not safe everywhere, which is why the default
    # is unbounded: an STI grandchild reads its grandparent's reflection
    # (`reflect_on_all_associations`, `_validators` and the callback chain
    # are all inherited), so `SportsCar < Car < Vehicle` has content that
    # changes when `Vehicle` changes while sitting two hops away in the
    # graph. A nested `has_many :through` resolves through the same kind of
    # chain. Set this only on a tree you know has neither.
    #
    # @param value [Integer, nil] must be a positive Integer, or nil
    # @raise [ConfigurationError] otherwise
    def incremental_blast_radius_depth=(value)
      @incremental_blast_radius_depth = validate_optional_positive_integer!(
        :incremental_blast_radius_depth, value
      )
    end

    # Application event APIs {Woods::Extractors::EventExtractor} recognizes
    # alongside its built-in ActiveSupport::Notifications and Wisper patterns.
    #
    # Each entry names a +role+ (+:publisher+ or +:subscriber+), a +pattern+
    # whose first capture group is the event name, and a +system+ label
    # recorded in event metadata. The label never enters the unit identifier.
    # A pattern with named groups names the event with +(?<name>...)+ and may
    # add +(?<scope>...)+, recorded in +metadata.scopes+.
    #
    # @example
    #   config.event_patterns = [
    #     { role: :publisher, pattern: /Ledger\.emit\s*\(\s*:?["']?([\w.:-]+)/, system: :ledger }
    #   ]
    #
    # @param value [Array<Hash>] entries with +:role+, +:pattern+, +:system+
    # @raise [ConfigurationError] if any entry is malformed; the previous value is kept
    def event_patterns=(value)
      raise ConfigurationError, "event_patterns must be an Array, got #{value.inspect}" unless value.is_a?(Array)

      @event_patterns = value.each_with_index.map { |entry, index| validate_event_pattern!(entry, index) }.freeze
    end

    # Directories {Woods::Extractors::EventExtractor} scans for publish and
    # subscribe sites, relative to Rails.root. Defaults to +%w[app]+; a host
    # app whose event wrapper lives in +lib/+ adds it. Each entry is normalized
    # (+./lib/+ and +lib//+ name +lib+; +.+ is the root itself), so full and
    # incremental runs agree on it. Changing it needs a full extraction.
    #
    # @example
    #   config.event_paths = %w[app lib]
    #
    # @param value [Array<String>] non-empty list of relative directories
    # @raise [ConfigurationError] if the list or any entry is malformed; the previous value is kept
    def event_paths=(value)
      unless value.is_a?(Array) && value.any?
        raise ConfigurationError, "event_paths must be a non-empty Array, got #{value.inspect}"
      end

      @event_paths = value.each_with_index.map { |entry, index| validate_event_path!(entry, index) }.freeze
    end

    # Root-relative globs {Woods::Extractors::PoroExtractor} sweeps for Ruby
    # files that no file-based extractor claims (helpers, view models, routing
    # constraints, app-local libraries). `app/models` is always scanned.
    # `app/assets`, `app/javascript` and non-`.rb` matches are never swept.
    #
    # The value is part of the generation's configuration fingerprint: after
    # changing it, incremental extraction refuses until one full extraction.
    #
    # @example
    #   config.unclaimed_ruby_paths = ['app/helpers/**/*.rb', 'app/view_models/**/*.rb']
    #
    # @param value [Array<String>] relative glob patterns
    # @raise [ConfigurationError] if any entry is malformed; the previous value is kept
    def unclaimed_ruby_paths=(value)
      raise ConfigurationError, "unclaimed_ruby_paths must be an Array, got #{value.inspect}" unless value.is_a?(Array)

      value.each_with_index { |glob, index| validate_relative_glob!(glob, index) }
      @unclaimed_ruby_paths = value.map { |glob| glob.dup.freeze }.freeze
    end

    # Root-relative globs {Woods::Extractors::GraphQLOperationExtractor} scans
    # for client-side GraphQL operation documents. An empty list turns the
    # family off. Paths under `node_modules` never match.
    #
    # The value is part of the generation's configuration fingerprint: after
    # changing it, incremental extraction refuses until one full extraction.
    #
    # @example
    #   config.graphql_document_paths = ['app/javascript/**/*.graphql', 'client/**/*.{graphql,gql}']
    #
    # @param value [Array<String>] relative glob patterns
    # @raise [ConfigurationError] if any entry is malformed; the previous value is kept
    def graphql_document_paths=(value)
      unless value.is_a?(Array) && value.all? { |glob| GraphQLDocumentPaths.valid_glob?(glob) }
        raise ConfigurationError, "graphql_document_paths must be an Array of relative globs, got #{value.inspect}"
      end

      @graphql_document_paths = value.map { |glob| glob.dup.freeze }.freeze
    end

    # Root-relative globs {Woods::Extractors::ConfigFileExtractor} indexes as
    # `config_file` units. Only `.yml` and `.yaml` matches are read.
    # `config/locales` belongs to the i18n extractor, and secret-bearing files
    # (`credentials*`, `secrets*`, `*.enc`, `*.key`, `config/credentials/`) are
    # never opened, whatever the globs say.
    #
    # The value is part of the generation's configuration fingerprint: after
    # changing it, incremental extraction refuses until one full extraction.
    #
    # @example
    #   config.config_file_paths = ['config/*.yml', 'config/settings/**/*.yml']
    #
    # @param value [Array<String>] relative glob patterns
    # @raise [ConfigurationError] if any entry is malformed; the previous value is kept
    def config_file_paths=(value)
      raise ConfigurationError, "config_file_paths must be an Array, got #{value.inspect}" unless value.is_a?(Array)

      value.each_with_index { |glob, index| validate_relative_glob!(glob, index, 'config_file_paths') }
      @config_file_paths = value.map { |glob| glob.dup.freeze }.freeze
    end

    # Whether `config_file` units store leaf values next to their key paths.
    # Off by default: only key paths are published. When on, a value under a
    # credential-named key, a credential-shaped value and ERB source are still
    # replaced by a marker.
    #
    # @param value [Boolean]
    # @raise [ConfigurationError] unless +value+ is true or false
    def config_file_values=(value)
      validate_boolean!('config_file_values', value)
      @config_file_values = value
    end

    # Settings constants built from a YAML file. A read through one
    # (`Settings.payments.api_host`, `Settings[:payments]`) adds a
    # `reads_config` edge from the reading unit to that file's unit.
    #
    # The value is part of the generation's configuration fingerprint: after
    # changing it, incremental extraction refuses until one full extraction.
    #
    # @example
    #   config.settings_readers = [{ constant: 'Settings', file: 'config/settings.yml' }]
    #
    # @param value [Array<Hash>] entries with a `constant` name and a root-relative `file`
    # @raise [ConfigurationError] if any entry is malformed; the previous value is kept
    def settings_readers=(value)
      raise ConfigurationError, "settings_readers must be an Array, got #{value.inspect}" unless value.is_a?(Array)

      @settings_readers = value.each_with_index.map { |entry, index| settings_reader(entry, index) }.freeze
    end

    # Other applications that read or write tables in this application's
    # database, declared so `dependents` of a table shows them. Each entry
    # becomes an `external_consumer` unit with `reads_table` and
    # `writes_table` edges to the table units. Plain data only: consumer
    # name => table names read, or `{ reads: [...], writes: [...] }`.
    #
    # @example
    #   config.external_table_consumers = {
    #     "storefront" => %w[products orders],
    #     "public-site" => { reads: %w[products], writes: %w[carts] }
    #   }
    #
    # @param value [Hash{String, Symbol => Array<String, Symbol>, Hash}]
    # @raise [ConfigurationError] if the declaration is malformed; the previous value is kept
    def external_table_consumers=(value)
      @external_table_consumers =
        Extractors::ExternalConsumerDeclarations.normalize!(value, label: 'external_table_consumers')
    end

    # A YAML file of the same shape as {#external_table_consumers=}, relative
    # to Rails.root, merged with it. A change to the file re-runs the
    # consumers on an incremental extraction, which a change to the
    # in-process setting cannot do.
    #
    # @example
    #   config.external_table_consumers_path = 'config/woods/external_consumers.yml'
    #
    # @param value [String, nil] relative path, or nil for no file
    # @raise [ConfigurationError] unless nil or a relative path without `..`; the previous value is kept
    def external_table_consumers_path=(value)
      @external_table_consumers_path =
        Extractors::ExternalConsumerDeclarations.normalize_path!(value, label: 'external_table_consumers_path')
    end

    # Globs, relative to Rails.root, whose Ruby files become `test_support`
    # units: helper modules, shared examples and contexts, custom matchers,
    # and suite configuration. `*_spec.rb` and `*_test.rb` files are never
    # test support, whatever the globs match.
    #
    # The value is part of the generation's configuration fingerprint: after
    # changing it, incremental extraction refuses until one full extraction.
    #
    # @example
    #   config.test_support_paths += ['features/support/**/*.rb']
    #
    # @param value [Array<String>] relative glob patterns
    # @raise [ConfigurationError] if any entry is malformed; the previous value is kept
    def test_support_paths=(value)
      raise ConfigurationError, "test_support_paths must be an Array, got #{value.inspect}" unless value.is_a?(Array)

      value.each_with_index { |glob, index| validate_relative_glob!(glob, index, 'test_support_paths') }
      @test_support_paths = value.map { |glob| glob.dup.freeze }.freeze
    end

    # Names of test helper methods that switch the subdomain a test's requests
    # use, called with a literal: `with_subdomain("shop") { ... }`. A literal
    # path in a test is matched against subdomain-constrained routes using
    # the one subdomain its file names.
    #
    # @example
    #   config.test_subdomain_helpers += ['on_storefront']
    #
    # @param value [Array<String>] method names
    # @raise [ConfigurationError] if any entry is not a method name; the previous value is kept
    def test_subdomain_helpers=(value)
      unless value.is_a?(Array)
        raise ConfigurationError, "test_subdomain_helpers must be an Array, got #{value.inspect}"
      end

      value.each_with_index do |name, index|
        next if name.is_a?(String) && name.match?(/\A[a-z_]\w*[?!]?\z/)

        raise ConfigurationError, "test_subdomain_helpers[#{index}] must be a method name, got #{name.inspect}"
      end
      @test_subdomain_helpers = value.map { |name| name.dup.freeze }.freeze
    end

    # Which unit types publish verified +code_reference+ edges from the
    # source-reference pass, and which target types each may reference.
    #
    # The Hash names only the caller types to change; every other type keeps
    # its default ({Woods::SourceReferences::CallerPolicy::DEFAULTS}). A value
    # is +:all+, an Array of target types, or +false+ to stop that type being
    # a caller. By default every constant-owned type is a caller of every
    # type, except that components add no edge to components and GraphQL
    # units add none to GraphQL units.
    #
    # The policy is recorded in the source-reference cache: after changing
    # it, incremental extraction refuses to run until one full extraction.
    #
    # @example
    #   config.source_reference_callers = { component: %i[model service], mailer: false }
    #
    # @param value [Hash{Symbol, String => Symbol, Array, false}] caller type to targets
    # @raise [ConfigurationError] for an unknown type or malformed entry; the previous value is kept
    def source_reference_callers=(value)
      @source_reference_callers = SourceReferences::CallerPolicy.normalize(value)
    end

    # Files {Woods::Extractors::RakeTaskExtractor} reads for task definitions,
    # relative to Rails.root. Ruby files under a listed directory are indexed
    # as the tasks' support code.
    #
    # The value is part of the generation's configuration fingerprint: after
    # changing it, incremental extraction refuses until one full extraction.
    #
    # @example
    #   config.rake_task_paths = ['lib/tasks/**/*.rake', 'ops/*.rake', 'Rakefile']
    #
    # @param value [Array<String>] file paths, +dir/**/*.ext+ or +dir/*.ext+ globs
    # @raise [ConfigurationError] if any entry is malformed; the previous value is kept
    def rake_task_paths=(value)
      @rake_task_paths = Extractors::RakeTaskPaths.validate!(value)
    end

    # One SHA-256 digest per {EXTRACTION_KEYS} entry, over a canonical JSON
    # form of its value. Per-key digests let a refusal name what changed
    # without the manifest or a message ever carrying a value.
    #
    # @return [Hash{String => String}] key name => hex digest
    def extraction_fingerprint
      EXTRACTION_KEYS.to_h do |key|
        [key.to_s, Digest::SHA256.hexdigest(JSON.generate(fingerprint_form(public_send(key))))]
      end
    end

    # Root-relative globs {Woods::Extractors::JsModuleExtractor} scans for
    # JavaScript and TypeScript modules. Vendored, generated, minified and
    # declaration files are never indexed; see {Woods::JavascriptPaths}. An
    # empty list disables the unit type.
    #
    # The value is part of the generation's configuration fingerprint: after
    # changing it, incremental extraction refuses until one full extraction.
    #
    # @example
    #   config.javascript_paths = ['app/javascript/**/*.{js,ts}', 'frontend/src/**/*.{ts,tsx}']
    #
    # @param value [Array<String>] relative glob patterns
    # @raise [ConfigurationError] if any entry is malformed; the previous value is kept
    def javascript_paths=(value)
      @javascript_paths = JavascriptPaths.validate!(value)
    end

    # Root-relative globs {Woods::Extractors::DocExtractor} indexes as `doc`
    # units. An empty Array disables documentation units. A glob under a
    # hidden directory other than `.claude/rules`, `.claude/skills` and
    # `.github` is refused: source capture and the watch daemon never read one.
    #
    # The value is part of the generation's configuration fingerprint: after
    # changing it, incremental extraction refuses until one full extraction.
    #
    # @example
    #   config.documentation_paths += ['handbook/**/*.md']
    #
    # @param value [Array<String>] relative glob patterns
    # @raise [ConfigurationError] if any entry is malformed; the previous value is kept
    def documentation_paths=(value)
      @documentation_paths = validate_documentation_globs!('documentation_paths', value, visible: true)
    end

    # Root-relative globs removed from {#documentation_paths}.
    #
    # The value is part of the generation's configuration fingerprint: after
    # changing it, incremental extraction refuses until one full extraction.
    #
    # @param value [Array<String>] relative glob patterns
    # @raise [ConfigurationError] if any entry is malformed; the previous value is kept
    def documentation_exclude=(value)
      @documentation_exclude = validate_documentation_globs!('documentation_exclude', value, visible: false)
    end

    # Whether retrieval includes `doc` units by default. When false they are
    # excluded like `test_mapping` units, and a caller reaches them with an
    # explicit `types:` filter.
    #
    # @param value [Boolean]
    # @raise [ConfigurationError] unless +value+ is true or false
    def retrieve_documentation=(value)
      validate_boolean!('retrieve_documentation', value)
      @retrieve_documentation = value
    end

    # Accepted for forward compatibility. Nothing reads {gem_configs}; gem
    # source indexing is not implemented.
    #
    # @param gem_name [String] Name of the gem
    # @param paths [Array<String>] Relative paths within the gem to index
    # @param priority [Symbol] :high, :medium, or :low
    def add_gem(gem_name, paths:, priority: :medium)
      warn 'config.add_gem is accepted for forward compatibility but gem configs are not used.'
      @gem_configs[gem_name] = { paths: paths, priority: priority }
    end

    private

    # Hash keys are sorted so a declaration's insertion order never changes
    # the digest. A Regexp keeps its options: `/x/i` and `/x/` match differently.
    def fingerprint_form(value)
      case value
      when Hash then value.map { |key, item| [key.to_s, fingerprint_form(item)] }.sort_by(&:first)
      when Array then value.map { |item| fingerprint_form(item) }
      when Regexp then { 'source' => value.source, 'options' => value.options }
      else value
      end
    end

    # @return [Integer] +value+ when it is a positive Integer
    # @raise [ConfigurationError] otherwise
    def validate_positive_integer!(name, value)
      return value if value.is_a?(Integer) && value.positive?

      raise ConfigurationError, "#{name} must be a positive Integer, got #{value.inspect}"
    end

    # @return [Integer, nil] +value+ when it is nil or a positive Integer
    # @raise [ConfigurationError] otherwise
    def validate_optional_positive_integer!(name, value)
      return value if value.nil?
      return value if value.is_a?(Integer) && value.positive?

      raise ConfigurationError, "#{name} must be a positive Integer or nil, got #{value.inspect}"
    end

    # @return [Hash] a frozen copy of +entry+ holding only +:role+, +:pattern+ and +:system+
    # @raise [ConfigurationError] if +entry+ is malformed
    def validate_event_pattern!(entry, index)
      label = "event_patterns[#{index}]"
      raise ConfigurationError, "#{label} must be a Hash, got #{entry.inspect}" unless entry.is_a?(Hash)

      role, pattern, system = entry.values_at(:role, :pattern, :system)
      unless %i[publisher subscriber].include?(role)
        raise ConfigurationError, "#{label} role must be :publisher or :subscriber, got #{role.inspect}"
      end
      raise ConfigurationError, "#{label} pattern must be a Regexp, got #{pattern.inspect}" unless pattern.is_a?(Regexp)

      validate_event_name_capture!(label, pattern)
      raise ConfigurationError, "#{label} system must be a Symbol, got #{system.inspect}" unless system.is_a?(Symbol)

      { role: role, pattern: pattern, system: system }.freeze
    end

    # @raise [ConfigurationError] unless +pattern+ captures an event name
    def validate_event_name_capture!(label, pattern)
      # Named groups make every unnamed group non-capturing, so group 1 would
      # be whichever named group comes first.
      if pattern.names.any? && !pattern.names.include?('name')
        raise ConfigurationError,
              "#{label} pattern has named capture groups but no (?<name>...) group for the event name, " \
              "got #{pattern.inspect}"
      end
      # The empty alternative always matches, so `captures` counts the groups.
      return unless /#{pattern}|/.match('').captures.empty?

      raise ConfigurationError,
            "#{label} pattern must have a capture group for the event name, got #{pattern.inspect}"
    end

    # @return [String] +entry+ without empty or +.+ segments (+.+ for the root itself), frozen
    # @raise [ConfigurationError] unless +entry+ is a relative path inside Rails.root
    def validate_event_path!(entry, index)
      label = "event_paths[#{index}]"
      unless entry.is_a?(String) && !entry.empty?
        raise ConfigurationError, "#{label} must be a non-empty String, got #{entry.inspect}"
      end
      if entry.start_with?('/') || entry.split('/').include?('..')
        raise ConfigurationError, "#{label} must be relative to Rails.root, got #{entry.inspect}"
      end

      normalized_relative_dir(entry)
    end

    # @return [String] +path+ without empty or +.+ segments, +.+ when none remain, frozen
    def normalized_relative_dir(path)
      segments = path.split('/').reject { |segment| segment.empty? || segment == '.' }
      (segments.empty? ? '.' : segments.join('/')).freeze
    end

    # Brace delimiters count as segment boundaries, so +{../shared,app}+ is
    # refused like +../shared+.
    #
    # @raise [ConfigurationError] unless +glob+ is a non-empty, relative path glob without `..`
    def validate_relative_glob!(glob, index, name = 'unclaimed_ruby_paths')
      return if glob.is_a?(String) && !glob.empty? && !glob.start_with?('/') &&
                !glob.tr('{},', '///').split('/').include?('..')

      raise ConfigurationError, "#{name}[#{index}] must be a relative glob, got #{glob.inspect}"
    end

    SETTINGS_CONSTANT = /\A(?:::)?[A-Z]\w*+(?:::[A-Z]\w*+)*+\z/
    private_constant :SETTINGS_CONSTANT

    # @return [Hash] a frozen `{ constant:, file: }` entry
    # @raise [ConfigurationError] unless the entry names a constant and a root-relative file
    def settings_reader(entry, index)
      label = "settings_readers[#{index}]"
      raise ConfigurationError, "#{label} must be a Hash, got #{entry.inspect}" unless entry.is_a?(Hash)

      constant = entry[:constant] || entry['constant']
      file = entry[:file] || entry['file']
      unless constant.is_a?(String) && SETTINGS_CONSTANT.match?(constant)
        raise ConfigurationError, "#{label} constant must be a constant name, got #{constant.inspect}"
      end

      validate_relative_glob!(file, index, 'settings_readers file')
      { constant: constant.delete_prefix('::').freeze, file: file.dup.freeze }.freeze
    end

    # @return [Array<String>] a frozen copy of +value+
    # @raise [ConfigurationError] if +value+ or any entry is malformed
    def validate_documentation_globs!(name, value, visible:)
      raise ConfigurationError, "#{name} must be an Array, got #{value.inspect}" unless value.is_a?(Array)

      require 'woods/watch/tree_scan'
      value.each_with_index do |glob, index|
        validate_relative_glob!(glob, index, name)
        next unless visible && Watch::TreeScan.hidden?(glob)

        raise ConfigurationError, "#{name}[#{index}] is under a hidden directory Woods does not read, " \
                                  "got #{glob.inspect}"
      end
      value.map { |glob| glob.dup.freeze }.freeze
    end

    def validate_boolean!(name, value)
      return if value.is_a?(TrueClass) || value.is_a?(FalseClass)

      raise ConfigurationError, "#{name} must be true or false, got #{value.inspect}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # Module Interface
  # ════════════════════════════════════════════════════════════════════════

  class << self
    attr_accessor :configuration

    def configure
      CONFIG_MUTEX.synchronize do
        self.configuration ||= Configuration.new
        yield(configuration) if block_given?
        configuration
      end
    end

    # Configure the module using a named preset and optional block customization.
    #
    # Valid preset names: :local, :shared_filesystem, :postgresql, :production
    #
    # @param name [Symbol] Preset name
    # @yield [config] Optional block for further customization after preset is applied
    # @yieldparam config [Configuration] The configuration object
    # @return [Configuration] The applied configuration
    def configure_with_preset(name)
      CONFIG_MUTEX.synchronize do
        self.configuration = Builder.preset_config(name)
        yield configuration if block_given?
        configuration
      end
    end

    # Resolve the effective Notion API token.
    #
    # A non-blank +NOTION_API_TOKEN+ env var takes precedence; otherwise the
    # configured +notion_api_token+ is used. A set-but-blank env var — common
    # with docker-compose +${NOTION_API_TOKEN}+ interpolation of an unset
    # host variable — is treated as absent, so it never masks a valid
    # configured token nor slips through as a blank bearer. This is the single
    # resolution point shared by the Notion exporter, the MCP +notion_sync+
    # tool + its registration gate, and the rake task, so all four agree on a
    # given host.
    #
    # @param config [Configuration] configuration to read the fallback from
    # @return [String, nil] the resolved token, or nil when neither source
    #   supplies a non-blank value
    def resolve_notion_token(config = configuration)
      env = ENV.fetch('NOTION_API_TOKEN', nil)
      return env unless env.nil? || env.strip.empty?

      configured = config.respond_to?(:notion_api_token) ? config.notion_api_token : nil
      return nil if configured.nil? || configured.to_s.strip.empty?

      configured
    end

    # Build a Retriever wired with adapters from the current configuration.
    #
    # @return [Retriever] A fully wired retriever instance
    def build_retriever
      Builder.new(configuration).build_retriever
    end

    # Retrieve context for a natural language query using the current configuration.
    #
    # @param query [String] Natural language query
    # @param opts [Hash] Options passed through to the retriever (e.g., budget:)
    # @return [Retriever::RetrievalResult] Retrieval result
    def retrieve(query, **opts)
      build_retriever.retrieve(query, **opts)
    end

    # Perform full extraction
    #
    # @param output_dir [String] Override output directory
    # @return [Hash] Extraction results
    def extract!(output_dir: nil)
      dir = output_dir || configuration.output_dir
      with_extraction_writer(dir, &:extract_all)
    end

    # Perform incremental extraction
    #
    # @param changed_files [Array<String>] List of changed files
    # @return [Array<String>] Re-extracted unit identifiers
    def extract_changed!(changed_files)
      with_extraction_writer(configuration.output_dir) { |extractor| extractor.extract_changed(changed_files) }
    end

    private

    # One-shot public callers share the task/watch writer lock. Unlike a rake
    # task, a library caller needs a typed timeout exception, not process exit.
    def with_extraction_writer(output_dir)
      require_relative 'woods/extractor'
      require_relative 'woods/rake_helpers'

      RakeHelpers.woods_with_extraction_lock(output_dir, raise_on_timeout: true) do
        extractor = Extractor.new(output_dir: output_dir)
        result = yield extractor
        extractor.raise_on_publication_failure!
        result
      end
    end
  end

  # Initialize with defaults
  configure
end

require_relative 'woods/builder'
require_relative 'woods/cost_model'
require_relative 'woods/cache/cache_store'
require_relative 'woods/cache/cache_middleware'
require_relative 'woods/railtie' if defined?(Rails::Railtie)
