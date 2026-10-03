# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'
require_relative '../javascript_paths'
require_relative 'js_module_registry'

module Woods
  module Extractors
    # JsModuleExtractor emits one shallow `js_module` unit per JavaScript or
    # TypeScript file under the configured roots.
    #
    # Shallow by design: there is no JavaScript toolchain and no AST. A linear
    # token pass ({JsTokenizer}) yields imports, exports and framework
    # registrations; {JsModuleRegistry} resolves them across files. Units are
    # identified by root-relative path and carry `via: :import` edges to the
    # local modules they import.
    #
    # A module's metadata depends on other files (the names it is registered
    # under come from whichever file registers them), so incremental runs
    # replace the type wholesale.
    #
    # @example
    #   units = JsModuleExtractor.new.extract_all
    #   unit = units.find { |u| u.identifier == "app/javascript/controllers/clipboard_controller.js" }
    #   unit.metadata[:kind]             # => "stimulus_controller"
    #   unit.metadata[:registered_names] # => [{ kind: "stimulus_controller", name: "clipboard", source: "filename" }]
    class JsModuleExtractor
      # Files larger than this keep their metadata but not their source.
      MAX_SOURCE_BYTES = 200 * 1024

      TYPESCRIPT_EXTENSIONS = %w[.ts .tsx].freeze

      def initialize
        @root = Rails.root.to_s
      end

      # Extract every module under the configured roots.
      #
      # @return [Array<ExtractedUnit>] sorted by identifier
      def extract_all
        registry.paths.filter_map { |relative| build_unit(relative) }
      end

      # Extract a single module file.
      #
      # @param file_path [String] absolute path
      # @return [ExtractedUnit, nil] nil when the path is not module source
      def extract_js_module_file(file_path)
        relative = file_path.to_s.delete_prefix("#{@root}/")
        return nil unless JavascriptPaths.source?(relative) && registry.facts(relative)

        build_unit(relative)
      end

      private

      def registry
        @registry ||= JsModuleRegistry.current(@root)
      end

      def build_unit(relative)
        path = File.join(@root, relative)
        source = read_source(path, relative)
        unit = ExtractedUnit.new(type: :js_module, identifier: relative, file_path: path)
        unit.namespace = File.dirname(relative)
        unit.source_code = source || ''
        unit.metadata = build_metadata(relative, source)
        unit.dependencies = build_dependencies(relative)
        unit
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract JavaScript module #{relative}: #{e.message}")
        nil
      end

      # @return [String, nil] nil when the file is over {MAX_SOURCE_BYTES}
      def read_source(path, relative)
        return nil if registry.bytesize(relative).to_i > MAX_SOURCE_BYTES

        File.read(path, encoding: Encoding::UTF_8).scrub('?')
      end

      def build_metadata(relative, source)
        facts = registry.facts(relative)
        metadata = {
          kind: registry.kind(relative),
          language: TYPESCRIPT_EXTENSIONS.include?(File.extname(relative)) ? 'typescript' : 'javascript',
          default_export: facts.default_export,
          has_default_export: facts.default_export?,
          named_exports: facts.named_exports,
          imports: registry.resolved_imports(relative),
          registered_names: registry.registered_names(relative),
          source_bytes: registry.bytesize(relative)
        }
        metadata[:loc] = source.lines.count { |line| line.strip.length.positive? } if source
        add_optional_metadata(metadata, relative, facts, source)
      end

      def add_optional_metadata(metadata, relative, facts, source)
        registers = registry.registrations_in(relative)
        metadata[:registers] = registers if registers.any?
        metadata[:stimulus_loaders] = facts.stimulus_loaders if facts.stimulus_loaders.any?
        metadata[:source_omitted] = true if source.nil?
        metadata[:analysis_omitted] = true if registry.analysis_omitted?(relative)
        metadata
      end

      def build_dependencies(relative)
        registry.resolved_imports(relative).filter_map { |entry| entry[:resolved] }
                .reject { |target| target == relative }.uniq.sort
                .map { |target| { type: :js_module, target: target, via: :import } }
      end
    end
  end
end
