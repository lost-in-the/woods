# frozen_string_literal: true

module Woods
  module Extractors
    module ViewEngines
      # Abstract base class documenting the TemplateEngine contract that
      # {ViewTemplateExtractor} dispatches to.
      #
      # Concrete engines (e.g. {Erb}, and future HAML / Slim / Turbo
      # implementations) subclass Base and override the abstract methods.
      # The orchestrator consults the engine collection via
      # {ViewTemplateExtractor::ENGINES}, finds the first engine whose
      # {#handles?} returns true for a file, and delegates parsing,
      # scanning, and partial-identifier resolution to that engine.
      #
      # Base intentionally does NOT prescribe an engine-neutral AST — the
      # original #110 design sketched a `parse(source) -> ast` step, but
      # HAML/Slim compile to engine-specific intermediate representations
      # (Temple expressions, indented line trees) that resist a shared
      # shape. Instead each `scan_*` method accepts raw source and the
      # engine is free to parse it however it likes before returning the
      # flat result type the orchestrator needs.
      #
      # @abstract Subclass and override all abstract methods.
      #
      # @example Minimal engine
      #   class Haml < Woods::Extractors::ViewEngines::Base
      #     def name = :haml
      #     def extensions = %w[.html.haml .haml].freeze
      #     def scan_partials(source); ...; end
      #     def scan_instance_variables(source); ...; end
      #     def scan_helpers(source); ...; end
      #     def resolve_partial_identifier(partial_name, current_identifier); ...; end
      #   end
      class Base
        # Stable engine identifier surfaced through
        # {ViewTemplateExtractor.supported_template_engines} and the MCP
        # `structure` tool.
        #
        # @return [Symbol]
        def name
          raise NotImplementedError, "#{self.class.name} must implement #name"
        end

        # File extensions this engine handles, each including the leading
        # dot (e.g. `.html.erb`).
        #
        # @return [Array<String>]
        def extensions
          raise NotImplementedError, "#{self.class.name} must implement #extensions"
        end

        # Whether this engine handles the given file path. The default
        # implementation suffix-matches against {#extensions}; engines
        # with more elaborate discrimination (e.g. looking at file
        # content) can override.
        #
        # @param file_path [String]
        # @return [Boolean]
        def handles?(file_path)
          extensions.any? { |ext| file_path.end_with?(ext) }
        end

        # Partial names referenced by render calls in the given source.
        # Returns the raw partial names as they appear in render calls
        # (e.g. `'comments/comment'`, `'sidebar'`, `'header'`); the
        # orchestrator calls {#resolve_partial_identifier} per entry to
        # translate each into a canonical file identifier.
        #
        # @param source [String] Template source code
        # @return [Array<String>]
        def scan_partials(_source)
          raise NotImplementedError, "#{self.class.name} must implement #scan_partials"
        end

        # Instance-variable names referenced in the template source,
        # returned sorted and deduplicated (including the leading `@`).
        #
        # @param source [String] Template source code
        # @return [Array<String>]
        def scan_instance_variables(_source)
          raise NotImplementedError, "#{self.class.name} must implement #scan_instance_variables"
        end

        # Helper method names detected in the template source, returned
        # sorted. The set of "helpers" is engine-defined — ERB scans for
        # the common Rails view-helper vocabulary, HAML/Slim would scan
        # the same vocabulary in their own syntaxes.
        #
        # @param source [String] Template source code
        # @return [Array<String>]
        def scan_helpers(_source)
          raise NotImplementedError, "#{self.class.name} must implement #scan_helpers"
        end

        # Resolve a partial name (as it appeared in a render call) to the
        # file identifier of the partial template. Engines own this
        # because the filename convention is engine-specific: ERB looks
        # for `_foo.html.erb`, HAML for `_foo.html.haml`, etc.
        #
        # @param partial_name [String] The partial name from the render call
        # @param current_identifier [String] Identifier of the template
        #   issuing the render, used to anchor relative partial names
        # @return [String]
        def resolve_partial_identifier(_partial_name, _current_identifier)
          raise NotImplementedError,
                "#{self.class.name} must implement #resolve_partial_identifier"
        end
      end
    end
  end
end
