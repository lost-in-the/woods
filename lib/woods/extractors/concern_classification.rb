# frozen_string_literal: true

require 'monitor'
require 'pathname'
require 'set'
require_relative '../source_file'
require_relative '../source_references/collector'
require_relative '../source_references/runtime_lookup'

module Woods
  module Extractors
    # The one answer, per extraction run, to "is this module a concern?" (#996).
    #
    # A module is a concern when either holds:
    # - **directory rule:** its file sits under an `app/**/concerns` directory;
    # - **runtime rule:** the loaded module extends `ActiveSupport::Concern`,
    #   checked as `mod.singleton_class.include?(ActiveSupport::Concern)`.
    #
    # The runtime check is by name only. Each module a candidate file declares
    # is resolved through its constant name, without autoloading, and the
    # resolved module is asked the question above. Nothing walks the object
    # heap, and nothing reads source text to decide.
    #
    # **Limit:** a module that is never loaded has no runtime answer, so it
    # keeps the type its other rules give it (`poro`, `lib`). That is not a
    # claim about what the module is.
    #
    # One instance is shared by every reader of a run: {ConcernExtractor},
    # the PORO extractor's {StandaloneModuleDiscovery}, {LibExtractor} and the
    # orchestrator's module reconciliation. Its sets are computed once, under a
    # lock, so concurrent extraction threads read the same answer.
    class ConcernClassification
      # Canonical concern directories, used when the glob finds none.
      CONCERN_DIRECTORIES = %w[app/models/concerns app/controllers/concerns].freeze

      # Files whose declared modules the runtime rule examines. Concern
      # directories are excluded: the directory rule already owns them.
      CANDIDATE_GLOBS = %w[app/**/*.rb lib/**/*.rb].freeze

      # A file without the keyword declares no module; skip its parse.
      MODULE_KEYWORD = /\bmodule\s/

      CORE_SINGLETON = Object.instance_method(:singleton_class)
      CORE_INCLUDE = Module.instance_method(:include?)
      CORE_NAME = Module.instance_method(:name)
      CORE_SOURCE = Module.instance_method(:const_source_location)

      # @return [Array<Pathname>] concern directories the directory rule covers
      attr_reader :directories

      # @param root [Pathname, String] application root
      # @param collector [#call] declaration parser; a run passes its shared one
      def initialize(root: Rails.root, collector: nil)
        @root = File.expand_path(root.to_s)
        @collector = collector || SourceReferences::Collector.new
        @lookup = SourceReferences::RuntimeLookup.new
        @monitor = Monitor.new
        @directories = discover_directories
      end

      # Directory rule.
      #
      # @param path [String, nil] absolute source path
      # @return [Boolean] whether the path sits in a concern directory
      def conventional_path?(path)
        return false unless path

        @directories.any? { |directory| path.to_s.start_with?("#{directory}/") }
      end

      # Runtime rule, for a module object already in hand.
      #
      # @param mod [Module]
      # @return [Boolean]
      def active_support_concern?(mod)
        return false unless defined?(ActiveSupport::Concern)
        return false unless @lookup.module_object?(mod) && !@lookup.class_object?(mod)

        CORE_INCLUDE.bind(CORE_SINGLETON.bind(mod).call).call(ActiveSupport::Concern)
      end

      # Runtime rule, by constant name.
      #
      # @param name [String] constant path
      # @return [Boolean, nil] nil when the name resolves to no loaded module
      def concern_answer(name)
        mod = loaded_module(name)
        mod.nil? ? nil : active_support_concern?(mod)
      end

      # Modules a model mixes in, by source path. Computed once per run by the
      # first {ConcernExtractor} that asks; every later reader shares it.
      #
      # @yieldreturn [Hash{String => Array<Module>}]
      # @return [Hash{String => Array<Module>}]
      def model_mixins
        @monitor.synchronize { @model_mixins ||= yield.freeze }
      end

      # Modules the runtime rule promotes: declared in an app or lib file
      # outside the concern directories, canonically declared there, loaded,
      # and extending ActiveSupport::Concern. Whether anything includes them
      # does not matter.
      #
      # @return [Hash{String => Array<Module>}] absolute path => modules, sorted by path
      def promoted_modules
        @monitor.synchronize { @promoted_modules ||= measure { discover_promoted }.freeze }
      end

      # Model mixins and promoted modules together, each module once. A module
      # both rules reach stays under the path the model-mixin rule gave it.
      #
      # @yieldreturn [Hash{String => Array<Module>}] model mixins, for {#model_mixins}
      # @return [Hash{String => Array<Module>}]
      def runtime_modules(&model_mixins)
        @monitor.synchronize do
          @runtime_modules ||= merge(self.model_mixins(&model_mixins), promoted_modules).freeze
        end
      end

      # Cost of the runtime rule's scan, for profiling (report only).
      #
      # @return [Hash{Symbol => Numeric}]
      def stats
        @monitor.synchronize { (@stats || {}).dup }
      end

      private

      def discover_directories
        found = Dir[File.join(@root, 'app/**/concerns')].map { |dir| Pathname.new(dir) }.select(&:directory?)
        return found unless found.empty?

        CONCERN_DIRECTORIES.map { |dir| Pathname.new(File.join(@root, dir)) }.select(&:directory?)
      end

      def measure
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @stats = { candidate_files: 0, parsed_files: 0, promoted: 0 }
        result = yield
        @stats[:promoted] = result.values.sum(&:size)
        @stats[:seconds] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        result
      end

      def discover_promoted
        return {} unless defined?(ActiveSupport::Concern)

        candidate_files.each_with_object({}) do |path, found|
          @stats[:candidate_files] += 1
          source = SourceFile.read(path)
          next unless source.match?(MODULE_KEYWORD)

          @stats[:parsed_files] += 1
          modules = declared_modules(source).filter_map do |identifier|
            mod = loaded_module(identifier)
            mod if mod && active_support_concern?(mod) && canonical_file(identifier) == File.realpath(path)
          end
          found[path] = modules unless modules.empty?
        rescue StandardError
          # An unreadable file gives no runtime answer; its modules keep their type.
          next
        end
      end

      def candidate_files
        configured = Woods.respond_to?(:configuration) ? Woods.configuration&.unclaimed_ruby_paths : nil
        globs = CANDIDATE_GLOBS + Array(configured)
        globs.flat_map { |glob| Dir.glob(glob, File::FNM_EXTGLOB, base: @root) }.uniq.sort
             .map { |relative| File.join(@root, relative) }
             .reject { |path| conventional_path?(path) || !File.file?(path) }
      end

      def declared_modules(source)
        @collector.call(source).fetch('declarations', []).filter_map do |declaration|
          next unless declaration['kind'] == 'module' && declaration.fetch('singleton_depth', 0).zero?

          declaration['owner']
        end.uniq
      end

      # @return [Module, nil] the loaded module the name spells, never autoloaded
      def loaded_module(name)
        return unless name.is_a?(String) && SourceReferences::RuntimeLookup::CONSTANT.match?(name)

        result = @lookup.call("::#{name.delete_prefix('::')}", allow_private: true)
        value = result[:value]
        return unless result[:status] == :resolved
        return unless @lookup.module_object?(value) && !@lookup.class_object?(value)

        value
      end

      # Ruby 3.1 can report [false, 0]; only a String naming a file counts.
      def canonical_file(identifier)
        location = CORE_SOURCE.bind(Object).call(identifier)
        file = location.is_a?(Array) ? location.first : nil
        File.realpath(file) if file.is_a?(String) && File.file?(file)
      rescue NameError
        nil
      end

      def merge(mixins, promoted)
        seen = mixins.values.flatten.to_set { |mod| CORE_NAME.bind(mod).call }
        merged = mixins.transform_values(&:dup)
        promoted.each do |path, modules|
          fresh = modules.reject { |mod| seen.include?(CORE_NAME.bind(mod).call) }
          (merged[path] ||= []).concat(fresh) unless fresh.empty?
        end
        merged
      end
    end
  end
end
