# frozen_string_literal: true

require_relative '../source_file'
require_relative '../source_inputs/consumer_errors'

require_relative 'line_neutralizer'
require_relative 'source_nesting'
require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'declaration_ancestry'

module Woods
  module Extractors
    # PunditExtractor handles Pundit authorization policy extraction.
    #
    # Specifically targets Pundit convention: classes in `app/policies/`
    # that inherit from ApplicationPolicy or follow Pundit patterns
    # (user/record attrs, action? methods). This is distinct from the
    # generic PolicyExtractor which handles domain eligibility policies.
    #
    # @example
    #   extractor = PunditExtractor.new
    #   units = extractor.extract_all
    #   post_policy = units.find { |u| u.identifier == "PostPolicy" }
    #
    class PunditExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Directories to scan for Pundit policies
      PUNDIT_DIRECTORIES = %w[
        app/policies
      ].freeze

      # Standard Pundit action methods
      PUNDIT_ACTIONS = %w[index? show? create? new? update? edit? destroy?].freeze

      # A line declaring the nested Scope class (line-scan fallback only).
      SCOPE_DECLARATION = /\Aclass\s+Scope(?![[:word:]:])/

      def initialize
        @directories = PUNDIT_DIRECTORIES.map { |d| Rails.root.join(d) }
                                         .select(&:directory?)
      end

      # Extract all Pundit policy classes
      #
      # @return [Array<ExtractedUnit>] List of Pundit policy units
      def extract_all
        find_files_in_directories(@directories).filter_map do |file|
          extract_pundit_file(file)
        end
      end

      # Extract a single Pundit policy file
      #
      # @param file_path [String] Path to the policy file
      # @return [ExtractedUnit, nil] The extracted unit or nil if not a Pundit policy
      def extract_pundit_file(file_path)
        source = SourceFile.read(file_path)
        class_name = extract_class_name(file_path, source)

        return nil unless class_name

        ancestry = DeclarationAncestry.new(source: source, identifier: class_name, file_path: file_path)
        return nil unless pundit_policy?(source, ancestry)

        unit = ExtractedUnit.new(
          type: :pundit_policy,
          identifier: class_name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(class_name)
        unit.source_code = annotate_source(source, class_name)
        unit.metadata = extract_metadata(source, class_name, ancestry)
        unit.dependencies = with_inheritance(extract_dependencies(source, class_name),
                                             inheritance_dependency(class_name, file_path: file_path))

        unit
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract Pundit policy #{file_path}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Class Discovery
      # ──────────────────────────────────────────────────────────────────────

      # Extract class name from source or infer from file path.
      #
      # @param file_path [String]
      # @param source [String]
      # @return [String, nil]
      def extract_class_name(file_path, source)
        # Zeitwerk-governed naming (G-1), then position-aware (#174), then
        # convention.
        governed_class_name(file_path, source) || qualified_first_class_name(source) || file_path
          .sub("#{Rails.root}/", '')
          .sub(%r{^app/policies/}, '')
          .sub('.rb', '')
          .split('/')
          .map { |s| s.split('_').map(&:capitalize).join }
          .join('::')
      end

      # Detect whether this is a Pundit policy.
      #
      # @param source [String] Ruby source code
      # @return [Boolean]
      def pundit_policy?(source, ancestry)
        return false if ancestry.foreign?

        ancestry.application_policy? ||
          (source.match?(/attr_reader\s+:user/) && source.match?(/attr_reader.*:record/)) ||
          (source.match?(/def\s+initialize\s*\(\s*user\s*,/) && source.match?(/def\s+\w+\?/))
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String]
      # @param class_name [String]
      # @return [String]
      def annotate_source(source, class_name)
        model = infer_model(class_name)
        actions = detect_authorization_actions(source)

        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Pundit Policy: #{class_name.ljust(53)}║
          # ║ Model: #{model.to_s.ljust(61)}║
          # ║ Actions: #{actions.join(', ').ljust(59)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

          #{source}
        ANNOTATION
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String]
      # @param class_name [String]
      # @return [Hash]
      def extract_metadata(source, class_name, ancestry)
        actions = detect_authorization_actions(source)
        {
          model: infer_model(class_name),
          authorization_actions: actions,
          standard_actions: actions & PUNDIT_ACTIONS,
          custom_actions: actions - PUNDIT_ACTIONS,
          has_scope_class: source.match?(/class\s+Scope\b/) || false,
          inherits_application_policy: ancestry.application_policy?,
          public_methods: extract_public_methods(source),
          class_methods: extract_class_methods(source),
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') },
          method_count: source.scan(/def\s+(?:self\.)?\w+/).size
        }
      end

      # Detect authorization action methods (public methods ending in ?).
      #
      # Methods of a nested +Scope+ class are not authorization actions, and
      # its +private+/+protected+ markers do not apply to the policy, so the
      # lines it spans are skipped.
      #
      # @param source [String]
      # @return [Array<String>]
      def detect_authorization_actions(source)
        methods = []
        in_private = false
        in_protected = false
        scope_lines = scope_class_lines(source)

        source.each_line.with_index(1) do |line, number|
          next if scope_lines.any? { |range| range.cover?(number) }

          stripped = line.strip

          in_private = true if stripped == 'private'
          in_protected = true if stripped == 'protected'
          in_private = false if stripped == 'public'
          in_protected = false if stripped == 'public'

          next if in_private || in_protected

          methods << ::Regexp.last_match(1) if stripped =~ /def\s+(\w+\?)/
        end

        methods.uniq
      end

      # Line ranges of every nested +Scope+ class, from its declaration to
      # its own +end+.
      #
      # Prism gives each class body's exact extent. Source Prism cannot parse
      # falls back to {#scope_class_lines_by_depth}.
      #
      # @param source [String]
      # @return [Array<Range>] 1-based line ranges
      def scope_class_lines(source)
        scopes = SourceNesting.lexical_scopes(source)
        return scope_class_lines_by_depth(source) unless scopes

        scopes.filter_map do |start, finish, name|
          segments = name.split('::')
          next unless segments.size > 1 && segments.last == 'Scope'

          line_at(source, start)..line_at(source, finish - 1)
        end
      end

      # Depth-tracked +Scope+ extents for source Prism cannot parse.
      #
      # Lines are read with comments stripped and string bodies blanked, and
      # every opener of an +end+-terminated block counts ({#block_opener?}:
      # class, module, def, do, begin, case, loops, statement-position
      # if/unless), so a method body inside the Scope no longer closes it. A
      # Scope still open at end of file extends to the end of the file.
      #
      # @param source [String]
      # @return [Array<Range>] 1-based line ranges
      def scope_class_lines_by_depth(source)
        ranges = []
        start = nil
        depth = 0

        LineNeutralizer.neutralize_lines(source).each.with_index(1) do |line, number|
          stripped = line.strip
          next if start.nil? && !stripped.match?(SCOPE_DECLARATION)

          start ||= number
          if stripped.match?(SourceNesting::END_LINE)
            depth -= 1
          elsif block_opener?(stripped)
            depth += 1
          end
          next if depth.positive?

          ranges << (start..number)
          start = nil
          depth = 0
        end

        ranges << (start..) if start
        ranges
      end

      # @param source [String]
      # @param offset [Integer] byte offset
      # @return [Integer] 1-based line number holding that byte
      def line_at(source, offset)
        source.byteslice(0, offset).count("\n") + 1
      end

      # Infer the model name from the policy class name.
      #
      # @param class_name [String]
      # @return [String]
      def infer_model(class_name)
        stripped = class_name.split('::').last
        stripped.sub(/Policy\z/, '')
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String]
      # @param class_name [String]
      # @return [Array<Hash>]
      def extract_dependencies(source, class_name)
        model = infer_model(class_name)
        deps = [{ type: :model, target: model, via: :authorization }]

        deps.concat(scan_model_dependencies(source))
        deps.concat(scan_service_dependencies(source))
        deps.concat(scan_config_dependencies(source))

        consolidate_dependencies(deps)
      end
    end
  end
end
