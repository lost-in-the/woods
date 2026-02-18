# frozen_string_literal: true

module CodebaseIndex
  module Extractors
    # ViewTemplateExtractor handles ERB view template extraction.
    #
    # Scans `app/views/` for `.html.erb` and `.erb` files and produces
    # one ExtractedUnit per template. Extracts render calls (partials),
    # instance variables, and helper method usage. Links partials via
    # dependencies and infers the owning controller from directory structure.
    #
    # This is an ERB-only MVP — HAML, Slim, and layout inheritance
    # are not yet supported.
    #
    # @example
    #   extractor = ViewTemplateExtractor.new
    #   units = extractor.extract_all
    #   index = units.find { |u| u.identifier == "users/index.html.erb" }
    #
    class ViewTemplateExtractor
      # Directories to scan for view templates
      VIEW_DIRECTORIES = %w[
        app/views
      ].freeze

      # Common Rails view helper methods to detect
      COMMON_HELPERS = %w[
        link_to
        button_to
        form_for
        form_with
        form_tag
        image_tag
        stylesheet_link_tag
        javascript_include_tag
        content_for
        yield
        render
        redirect_to
        truncate
        pluralize
        number_to_currency
        number_to_percentage
        number_with_delimiter
        time_ago_in_words
        distance_of_time_in_words
        simple_format
        sanitize
        raw
        safe_join
        content_tag
        tag
        mail_to
        url_for
        asset_path
        asset_url
      ].freeze

      def initialize
        @directories = VIEW_DIRECTORIES.map { |d| Rails.root.join(d) }
                                       .select(&:directory?)
      end

      # Extract all ERB view templates
      #
      # @return [Array<ExtractedUnit>] List of view template units
      def extract_all
        @directories.flat_map do |dir|
          erb_files = Dir[dir.join('**/*.html.erb')] + Dir[dir.join('**/*.erb')]
          erb_files.uniq.filter_map do |file|
            extract_view_template_file(file)
          end
        end
      end

      # Extract a single view template file
      #
      # @param file_path [String] Path to the ERB template file
      # @return [ExtractedUnit, nil] The extracted unit or nil if not ERB
      def extract_view_template_file(file_path)
        return nil unless file_path.end_with?('.erb')

        source = File.read(file_path)
        identifier = build_identifier(file_path)
        namespace = extract_view_namespace(file_path)

        unit = ExtractedUnit.new(
          type: :view_template,
          identifier: identifier,
          file_path: file_path
        )

        unit.namespace = namespace
        unit.source_code = source
        unit.metadata = build_metadata(source, file_path)
        unit.dependencies = build_dependencies(source, file_path, identifier)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract view template #{file_path}: #{e.message}")
        nil
      end

      private

      # Build a readable identifier from the file path.
      #
      # @param file_path [String] Absolute path to the template
      # @return [String] Relative identifier like "users/index.html.erb"
      def build_identifier(file_path)
        relative = file_path.sub("#{Rails.root}/", '')
        relative.sub(%r{^app/views/}, '')
      end

      # Extract namespace from directory structure.
      #
      # @param file_path [String] Absolute path
      # @return [String, nil] Namespace like "users" or "admin/users"
      def extract_view_namespace(file_path)
        identifier = build_identifier(file_path)
        dir = File.dirname(identifier)
        dir == '.' ? nil : dir
      end

      # Build metadata hash for the template.
      #
      # @param source [String] Template source code
      # @param file_path [String] Path to the template
      # @return [Hash]
      def build_metadata(source, file_path)
        {
          template_engine: 'erb',
          is_partial: partial?(file_path),
          partials_rendered: extract_rendered_partials(source),
          instance_variables: extract_instance_variables(source),
          helpers_called: extract_helpers(source),
          loc: source.lines.count { |l| l.strip.length.positive? }
        }
      end

      # Check if a template is a partial (filename starts with _).
      #
      # @param file_path [String] Path to the template
      # @return [Boolean]
      def partial?(file_path)
        File.basename(file_path).start_with?('_')
      end

      # Extract partial names from render calls.
      #
      # Matches:
      # - render partial: 'foo/bar'
      # - render 'foo/bar'
      # - render :foo
      #
      # @param source [String] Template source code
      # @return [Array<String>] Partial names
      def extract_rendered_partials(source)
        partials = Set.new

        # render partial: 'path/to/partial'
        source.scan(/render\s+partial:\s*['"]([^'"]+)['"]/).each do |match|
          partials << match[0]
        end

        # render 'path/to/partial' (string without keyword)
        source.scan(/render\s+['"]([^'"]+)['"]/).each do |match|
          partials << match[0]
        end

        # render :symbol
        source.scan(/render\s+:(\w+)/).each do |match|
          partials << match[0]
        end

        partials.to_a
      end

      # Extract instance variables used in the template.
      #
      # @param source [String] Template source code
      # @return [Array<String>] Instance variable names
      def extract_instance_variables(source)
        source.scan(/@[a-zA-Z_]\w*/).uniq.sort
      end

      # Extract common Rails helper calls from the template.
      #
      # @param source [String] Template source code
      # @return [Array<String>] Helper method names
      def extract_helpers(source)
        found = Set.new
        COMMON_HELPERS.each do |helper|
          found << helper if source.match?(/\b#{Regexp.escape(helper)}\b/)
        end
        found.to_a.sort
      end

      # Build dependencies for the template.
      #
      # @param source [String] Template source code
      # @param file_path [String] Path to the template
      # @param identifier [String] Template identifier
      # @return [Array<Hash>]
      def build_dependencies(source, file_path, identifier)
        deps = []

        # Rendered partials
        extract_rendered_partials(source).each do |partial_name|
          partial_identifier = resolve_partial_identifier(partial_name, identifier)
          deps << { type: :view_template, target: partial_identifier, via: :render }
        end

        # Inferred controller
        controller = infer_controller(file_path)
        deps << { type: :controller, target: controller, via: :view_render } if controller

        deps
      end

      # Resolve a partial name to its file identifier.
      #
      # Given a render call like `render 'comments/comment'`, resolves to
      # `comments/_comment.html.erb`.
      #
      # @param partial_name [String] The partial name from the render call
      # @param current_identifier [String] The current template's identifier
      # @return [String] Resolved partial identifier
      def resolve_partial_identifier(partial_name, current_identifier)
        if partial_name.include?('/')
          dir = File.dirname(partial_name)
          base = File.basename(partial_name)
          "#{dir}/_#{base}.html.erb"
        else
          dir = File.dirname(current_identifier)
          if dir == '.'
            "_#{partial_name}.html.erb"
          else
            "#{dir}/_#{partial_name}.html.erb"
          end
        end
      end

      # Infer the controller class from the template's directory path.
      #
      # @param file_path [String] Path to the template
      # @return [String, nil] Controller class name
      def infer_controller(file_path)
        namespace = extract_view_namespace(file_path)
        return nil unless namespace

        # Skip layout-only directories
        return nil if namespace == 'layouts'

        parts = namespace.split('/')
        controller_name = parts.map { |p| p.split('_').map(&:capitalize).join }.join('::')
        "#{controller_name}Controller"
      end
    end
  end
end
