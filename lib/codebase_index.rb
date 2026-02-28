# frozen_string_literal: true

# CodebaseIndex - Rails Codebase Indexing and Retrieval
#
# A system for extracting, indexing, and retrieving context from Rails codebases
# to enable AI-assisted development, debugging, and analytics.
#
# ## Quick Start
#
#   # Extract codebase
#   CodebaseIndex.extract!
#
#   # Or via rake
#   bundle exec rake codebase_index:extract
#
# ## Configuration
#
#   CodebaseIndex.configure do |config|
#     config.output_dir = Rails.root.join("tmp/codebase_index")
#     config.max_context_tokens = 8000
#     config.include_framework_sources = true
#   end
#
require_relative 'codebase_index/version'

module CodebaseIndex
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ExtractionError < Error; end
  class SessionTracerError < Error; end

  CONFIG_MUTEX = Mutex.new

  # ════════════════════════════════════════════════════════════════════════
  # Configuration
  # ════════════════════════════════════════════════════════════════════════

  class Configuration
    attr_accessor :embedding_model, :include_framework_sources, :gem_configs,
                  :vector_store, :metadata_store, :graph_store, :embedding_provider, :log_level,
                  :vector_store_options, :metadata_store_options, :embedding_options,
                  :concurrent_extraction, :precompute_flows, :enable_snapshots,
                  :session_tracer_enabled, :session_store, :session_id_proc, :session_exclude_paths,
                  :console_mcp_enabled, :console_mcp_path, :console_redacted_columns,
                  :notion_api_token, :notion_database_ids
    attr_reader :max_context_tokens, :similarity_threshold, :extractors, :pretty_json, :context_format

    def initialize # rubocop:disable Metrics/MethodLength
      @output_dir = nil # Resolved lazily; Rails.root is nil at require time
      @embedding_model = 'text-embedding-3-small'
      @max_context_tokens = 8000
      @similarity_threshold = 0.7
      @include_framework_sources = true
      @gem_configs = {}
      @extractors = %i[models controllers services components view_components jobs mailers graphql serializers
                       managers policies validators rails_source]
      @pretty_json = true
      @concurrent_extraction = false
      @precompute_flows = false
      @enable_snapshots = false
      @context_format = :markdown
      @session_tracer_enabled = false
      @session_store = nil
      @session_id_proc = nil
      @session_exclude_paths = []
      @console_mcp_enabled = false
      @console_mcp_path = '/mcp/console'
      @console_redacted_columns = []
      @notion_api_token = nil
      @notion_database_ids = {}
    end

    # @return [Pathname, String] Output directory, defaulting to Rails.root/tmp/codebase_index
    def output_dir
      @output_dir ||= defined?(Rails) && Rails.root ? Rails.root.join('tmp/codebase_index') : 'tmp/codebase_index'
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
      unless value.is_a?(TrueClass) || value.is_a?(FalseClass)
        raise ConfigurationError, "pretty_json must be true or false, got #{value.inspect}"
      end

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

    # Add a gem to be indexed
    #
    # @param gem_name [String] Name of the gem
    # @param paths [Array<String>] Relative paths within the gem to index
    # @param priority [Symbol] :high, :medium, or :low
    def add_gem(gem_name, paths:, priority: :medium)
      @gem_configs[gem_name] = { paths: paths, priority: priority }
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
      require_relative 'codebase_index/extractor'

      dir = output_dir || configuration.output_dir
      extractor = Extractor.new(output_dir: dir)
      extractor.extract_all
    end

    # Perform incremental extraction
    #
    # @param changed_files [Array<String>] List of changed files
    # @return [Array<String>] Re-extracted unit identifiers
    def extract_changed!(changed_files)
      require_relative 'codebase_index/extractor'

      extractor = Extractor.new(output_dir: configuration.output_dir)
      extractor.extract_changed(changed_files)
    end
  end

  # Initialize with defaults
  configure
end

require_relative 'codebase_index/builder'
require_relative 'codebase_index/cost_model'
require_relative 'codebase_index/railtie' if defined?(Rails::Railtie)
