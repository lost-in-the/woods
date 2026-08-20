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
require_relative 'woods/version'

module Woods
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ExtractionError < Error; end
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
    attr_accessor :include_framework_sources, :gem_configs,
                  :vector_store, :metadata_store, :graph_store, :embedding_provider, :log_level,
                  :vector_store_options, :metadata_store_options, :embedding_options,
                  :concurrent_extraction, :precompute_flows, :extract_navigation_edges, :enable_snapshots,
                  :session_tracer_enabled, :session_tracer_allow_production,
                  :session_store, :session_id_proc, :session_exclude_paths,
                  :console_mcp_enabled, :console_mcp_path, :console_mcp_token,
                  :console_mcp_allowed_origins,
                  :console_redacted_columns,
                  :console_redacted_key_values, :console_embedded_read_tools,
                  :console_blocked_tables, :console_disabled_scanner_patterns,
                  :console_credential_defense_enabled,
                  :console_credential_rotation_warning, :console_unsafe_eval_enabled,
                  :console_unsafe_eval_confirmation, :console_unsafe_eval_audit_log_path,
                  :notion_api_token, :notion_database_ids,
                  :unblocked_api_token, :unblocked_collection_id, :unblocked_repo_url,
                  :cache_store, :cache_options,
                  :dump_retention_count
    attr_reader :embedding_model, :max_context_tokens, :similarity_threshold, :extractors, :pretty_json,
                :context_format, :cache_enabled

    def initialize # rubocop:disable Metrics/MethodLength
      @output_dir = nil # Resolved lazily; Rails.root is nil at require time
      @embedding_model = 'text-embedding-3-small'
      @embedding_model_explicit = false
      @max_context_tokens = 8000
      @similarity_threshold = 0.7
      @include_framework_sources = true
      @gem_configs = {}
      @extractors = %i[models controllers services components view_components jobs mailers graphql serializers
                       managers policies validators rails_source]
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
      @console_mcp_path = '/mcp/console'
      # Accept token from config or env var. Nil by default — the railtie
      # refuses to wire the middleware in production without a real token
      # and only warns loudly in non-prod when unset.
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
      @unblocked_api_token = nil
      @unblocked_collection_id = nil
      @unblocked_repo_url = nil
      @cache_enabled = false
      @cache_store = nil      # :redis, :solid_cache, :memory, or a CacheStore instance
      @cache_options = {}     # { redis: client, cache: store, ttl: { embeddings: 86400, ... } }
      @dump_retention_count = 3
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

    # @param value [Numeric] Must be between 0.0 and 1.0 inclusive
    # @raise [ConfigurationError] if value is out of range or not numeric
    def similarity_threshold=(value)
      raise ConfigurationError, "similarity_threshold must be Numeric, got #{value.inspect}" unless value.is_a?(Numeric)

      float_val = value.to_f
      unless float_val.between?(0.0, 1.0)
        raise ConfigurationError, "similarity_threshold must be between 0.0 and 1.0, got #{value.inspect}"
      end

      @similarity_threshold = float_val
    end

    # @param value [Array<Symbol>] List of extractor names
    # @raise [ConfigurationError] if value is not an Array of Symbols
    def extractors=(value)
      unless value.is_a?(Array) && value.all?(Symbol)
        raise ConfigurationError, "extractors must be an Array of Symbols, got #{value.inspect}"
      end

      @extractors = value
    end

    # @param value [Boolean] Must be true or false
    # @raise [ConfigurationError] if value is not a boolean
    def pretty_json=(value)
      validate_boolean!(:pretty_json, value)
      @pretty_json = value
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

    # Add a gem to be indexed
    #
    # @param gem_name [String] Name of the gem
    # @param paths [Array<String>] Relative paths within the gem to index
    # @param priority [Symbol] :high, :medium, or :low
    def add_gem(gem_name, paths:, priority: :medium)
      @gem_configs[gem_name] = { paths: paths, priority: priority }
    end

    private

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
    # Valid preset names: :local, :postgresql, :production
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
      require_relative 'woods/extractor'

      dir = output_dir || configuration.output_dir
      extractor = Extractor.new(output_dir: dir)
      extractor.extract_all
    end

    # Perform incremental extraction
    #
    # @param changed_files [Array<String>] List of changed files
    # @return [Array<String>] Re-extracted unit identifiers
    def extract_changed!(changed_files)
      require_relative 'woods/extractor'

      extractor = Extractor.new(output_dir: configuration.output_dir)
      extractor.extract_changed(changed_files)
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
