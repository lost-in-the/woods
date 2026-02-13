# frozen_string_literal: true

module CodebaseIndex
  module Extractors
    # Utility methods shared across multiple extractors.
    #
    # Provides common helpers for namespace extraction, public method
    # scanning, class method scanning, and initialize parameter parsing.
    # These methods are duplicated across 4-11 extractors; this module
    # centralizes them.
    #
    # @example
    #   class FooExtractor
    #     include SharedUtilityMethods
    #
    #     def extract_foo(klass)
    #       namespace = extract_namespace(klass)
    #       # ...
    #     end
    #   end
    #
    module SharedUtilityMethods
      # Extract namespace from a class name string or class object.
      #
      # Handles both string input (e.g., "Payments::StripeService")
      # and class object input (e.g., a Controller class).
      #
      # @param name_or_object [String, Class, Module] A class name or class object
      # @return [String, nil] The namespace, or nil if top-level
      def extract_namespace(name_or_object)
        name = name_or_object.is_a?(String) ? name_or_object : name_or_object.name
        parts = name.split('::')
        parts.size > 1 ? parts[0..-2].join('::') : nil
      end

      # Extract public instance and class methods from source code.
      #
      # Walks source line-by-line tracking private/protected visibility.
      # Returns method names that are in public scope and don't start with underscore.
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Public method names
      def extract_public_methods(source)
        methods = []
        in_private = false
        in_protected = false

        source.each_line do |line|
          stripped = line.strip

          in_private = true if stripped == 'private'
          in_protected = true if stripped == 'protected'
          in_private = false if stripped == 'public'
          in_protected = false if stripped == 'public'

          if !in_private && !in_protected && stripped =~ /def\s+((?:self\.)?\w+[?!=]?)/
            method_name = ::Regexp.last_match(1)
            methods << method_name unless method_name.start_with?('_')
          end
        end

        methods
      end

      # Extract class-level (self.) method names from source code.
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Class method names
      def extract_class_methods(source)
        source.scan(/def\s+self\.(\w+[?!=]?)/).flatten
      end

      # Extract initialize parameters from source code.
      #
      # Parses the parameter list of the initialize method to determine
      # parameter names, defaults, and whether they are keyword arguments.
      #
      # @param source [String] Ruby source code
      # @return [Array<Hash>] Parameter info hashes with :name, :has_default, :keyword
      def extract_initialize_params(source)
        init_match = source.match(/def\s+initialize\s*\((.*?)\)/m)
        return [] unless init_match

        params_str = init_match[1]
        params = []

        params_str.scan(/(\w+)(?::\s*([^,\n]+))?/) do |name, default|
          params << {
            name: name,
            has_default: !default.nil?,
            keyword: params_str.include?("#{name}:")
          }
        end

        params
      end
    end
  end
end
