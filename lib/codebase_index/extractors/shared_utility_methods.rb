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
      # Extract the primary class name from source or fall back to a file path convention.
      #
      # @param file_path [String] Absolute path to the Ruby file
      # @param source [String] Ruby source code
      # @param dir_prefix [String] Regex fragment matching the app/ subdirectory to strip
      #   (e.g., "policies", "validators", "(?:services|interactors|operations|commands|use_cases)")
      # @return [String] The class name
      def extract_class_name(file_path, source, dir_prefix)
        return ::Regexp.last_match(1) if source =~ /^\s*class\s+([\w:]+)/

        file_path.sub("#{Rails.root}/", '').sub(%r{^app/#{dir_prefix}/}, '').sub('.rb', '').camelize
      end

      # Extract the parent class name from a class definition.
      #
      # @param source [String] Ruby source code
      # @return [String, nil] Parent class name or nil
      def extract_parent_class(source)
        match = source.match(/^\s*class\s+[\w:]+\s*<\s*([\w:]+)/)
        match ? match[1] : nil
      end

      # Count non-blank, non-comment lines of code.
      #
      # @param source [String] Ruby source code
      # @return [Integer] LOC count
      def count_loc(source)
        source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') }
      end

      # Skip module-only files (concerns, base modules without a class).
      #
      # @param source [String] Ruby source code
      # @return [Boolean]
      def skip_file?(source)
        source.match?(/^\s*module\s+\w+\s*$/) && !source.match?(/^\s*class\s+/)
      end

      # Extract custom error/exception class names defined inline.
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Custom error class names
      def extract_custom_errors(source)
        source.scan(/class\s+(\w+(?:Error|Exception))\s*</).flatten
      end

      # Detect common entry point methods in a source file.
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Entry point method names
      def detect_entry_points(source)
        points = []
        points << 'call'    if source.match?(/def (self\.)?call\b/)
        points << 'perform' if source.match?(/def (self\.)?perform\b/)
        points << 'execute' if source.match?(/def (self\.)?execute\b/)
        points << 'run'     if source.match?(/def (self\.)?run\b/)
        points << 'process' if source.match?(/def (self\.)?process\b/)
        points.empty? ? ['unknown'] : points
      end

      # Extract :only/:except action lists and :if/:unless conditions from a callback.
      #
      # Modern Rails (4.2+) stores conditions in @if/@unless ivar arrays.
      # ActionFilter objects hold action Sets; other conditions are procs/symbols.
      #
      # @param callback [ActiveSupport::Callbacks::Callback]
      # @return [Array(Array<String>, Array<String>, Array<String>, Array<String>)]
      #   [only_actions, except_actions, if_labels, unless_labels]
      def extract_callback_conditions(callback)
        if_conditions = callback.instance_variable_get(:@if) || []
        unless_conditions = callback.instance_variable_get(:@unless) || []

        only = []
        except = []
        if_labels = []
        unless_labels = []

        if_conditions.each do |cond|
          actions = extract_action_filter_actions(cond)
          if actions
            only.concat(actions)
          else
            if_labels << condition_label(cond)
          end
        end

        unless_conditions.each do |cond|
          actions = extract_action_filter_actions(cond)
          if actions
            except.concat(actions)
          else
            unless_labels << condition_label(cond)
          end
        end

        [only, except, if_labels, unless_labels]
      end

      # Extract action names from an ActionFilter-like condition object.
      # Duck-types on the @actions ivar being a Set, avoiding dependence
      # on private class names across Rails versions.
      #
      # @param condition [Object] A condition from the callback's @if/@unless array
      # @return [Array<String>, nil] Action names, or nil if not an ActionFilter
      def extract_action_filter_actions(condition)
        return nil unless condition.instance_variable_defined?(:@actions)

        actions = condition.instance_variable_get(:@actions)
        return nil unless actions.is_a?(Set)

        actions.to_a
      end

      # Human-readable label for a non-ActionFilter condition.
      #
      # @param condition [Object] A proc, symbol, or other condition
      # @return [String]
      def condition_label(condition)
        case condition
        when Symbol then ":#{condition}"
        when Proc then 'Proc'
        when String then condition
        else condition.class.name
        end
      end

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
