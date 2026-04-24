# frozen_string_literal: true

require 'set'
require_relative 'base'

module Woods
  module Extractors
    module ViewEngines
      # ERB implementation of the {Base} template-engine contract. Owns
      # the ERB-specific parsing surface that {ViewTemplateExtractor}
      # delegates to — extension list, partial filename convention, and
      # the three scan operations (partials, instance variables, helper
      # calls).
      class Erb < Base
        # File extensions this engine handles.
        EXTENSIONS = %w[.html.erb .erb].freeze

        # @see Base#name
        ENGINE_NAME = :erb

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

        # @see Base#name
        def name
          ENGINE_NAME
        end

        # @see Base#extensions
        def extensions
          EXTENSIONS
        end

        # Matches:
        # - `render partial: 'foo/bar'`
        # - `render 'foo/bar'`
        # - `render :foo`
        #
        # @see Base#scan_partials
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

        # @see Base#scan_instance_variables
        def scan_instance_variables(source)
          source.scan(/@[a-zA-Z_]\w*/).uniq.sort
        end

        # @see Base#scan_helpers
        def scan_helpers(source)
          found = Set.new
          COMMON_HELPERS.each do |helper|
            found << helper if source.match?(/\b#{Regexp.escape(helper)}\b/)
          end
          found.to_a.sort
        end

        # Given `render 'comments/comment'` from a template at
        # `posts/show.html.erb`, resolves to `comments/_comment.html.erb`.
        #
        # @see Base#resolve_partial_identifier
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
