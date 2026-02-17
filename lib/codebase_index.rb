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

  CONFIG_MUTEX = Mutex.new

  # ════════════════════════════════════════════════════════════════════════
  # Configuration
  # ════════════════════════════════════════════════════════════════════════

  class Configuration
    attr_accessor :embedding_model, :include_framework_sources, :gem_configs
    attr_reader :max_context_tokens, :similarity_threshold, :extractors, :pretty_json

    def initialize
      @output_dir = nil # Resolved lazily; Rails.root is nil at require time
      @embedding_model = 'text-embedding-3-small'
      @max_context_tokens = 8000
      @similarity_threshold = 0.7
      @include_framework_sources = true
      @gem_configs = {}
      @extractors = %i[models controllers services components view_components jobs mailers graphql serializers
                       managers policies validators rails_source]
      @pretty_json = true
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
      unless value.is_a?(Array) && value.all? { |v| v.is_a?(Symbol) }
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

require_relative 'codebase_index/railtie' if defined?(Rails::Railtie)
