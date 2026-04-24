# frozen_string_literal: true

require 'set'

module Woods
  module Extractors
    module ViewEngines
      # ERB template engine — owns the ERB-specific parsing surface that
      # {ViewTemplateExtractor} delegates to. Extension list, partial
      # filename convention, and the three scan operations (partials,
      # instance variables, helper calls) all live here so the orchestrator
      # stays engine-agnostic above the seam.
      #
      # HAML / Slim / Turbo implementations will land as sibling classes in
      # this namespace (see issue #110 for the non-goals).
      class Erb
        # File extensions this engine handles.
        EXTENSIONS = %w[.html.erb .erb].freeze

        # Symbol surfaced by {ViewTemplateExtractor.supported_template_engines}
        # and the MCP `structure` tool.
        ENGINE_NAME = :erb

        # @return [Symbol] Engine identifier — stable contract for the
        #   orchestrator so it never reads {ENGINE_NAME} through
        #   {Class#const_get}-style reach-through.
        def name
          ENGINE_NAME
        end

        # @return [Array<String>] Extensions this engine handles.
        def extensions
          EXTENSIONS
        end

        # Common Rails view helper methods to detect in template source.
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

        # Whether this engine handles the given file path.
        #
        # @param file_path [String]
        # @return [Boolean]
        def handles?(file_path)
          EXTENSIONS.any? { |ext| file_path.end_with?(ext) }
        end

        # Extract partial names from render calls.
        #
        # Matches:
        # - `render partial: 'foo/bar'`
        # - `render 'foo/bar'`
        # - `render :foo`
        #
        # @param source [String] Template source code
        # @return [Array<String>] Partial names
        def scan_partials(source)
          partials = Set.new

          source.scan(/render\s+partial:\s*['"]([^'"]+)['"]/).each do |match|
            partials << match[0]
          end

          source.scan(/render\s+['"]([^'"]+)['"]/).each do |match|
            partials << match[0]
          end

          source.scan(/render\s+:(\w+)/).each do |match|
            partials << match[0]
          end

          partials.to_a
        end

        # Extract instance variables used in the template.
        #
        # @param source [String] Template source code
        # @return [Array<String>] Instance variable names, sorted
        def scan_instance_variables(source)
          source.scan(/@[a-zA-Z_]\w*/).uniq.sort
        end

        # Extract common Rails helper calls from the template.
        #
        # @param source [String] Template source code
        # @return [Array<String>] Helper method names, sorted
        def scan_helpers(source)
          found = Set.new
          COMMON_HELPERS.each do |helper|
            found << helper if source.match?(/\b#{Regexp.escape(helper)}\b/)
          end
          found.to_a.sort
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
      end
    end
  end
end
