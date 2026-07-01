# frozen_string_literal: true

require 'set'
require_relative '../model_name_cache'
require_relative 'route_helper_resolver'

module Woods
  module Extractors
    # Common dependency scanning patterns shared across extractors.
    #
    # Most extractors scan source code for the same four dependency types:
    # model references (via ModelNameCache), service objects, background jobs,
    # and mailers. This module centralizes those scanning patterns.
    #
    # Individual scan methods accept an optional +:via+ parameter so
    # extractors can customize the relationship label (e.g., +:serialization+
    # instead of the default +:code_reference+).
    #
    # @example
    #   class FooExtractor
    #     include SharedDependencyScanner
    #
    #     def extract_dependencies(source)
    #       deps = scan_common_dependencies(source)
    #       deps << { type: :custom, target: "Bar", via: :special }
    #       deps.uniq { |d| [d[:type], d[:target]] }
    #     end
    #   end
    #
    module SharedDependencyScanner
      # Scan for ActiveRecord model references using the precomputed regex.
      #
      # Three passes:
      # 1. Fully-qualified names via the main `\b(?:Foo|Bar::Baz)\b` regex.
      # 2. `.constantize` / `const_get(...)` string-literal arguments —
      #    a `"Library::Book".constantize` used to return zero edges
      #    because the scan ran over raw source and the regex didn't pick
      #    up the quoted constant. Now we extract the string argument and
      #    resolve it.
      # 3. Bare short names (e.g. `Book` inside `module Library`)
      #    resolved through {ModelNameCache.resolve_short_name} when
      #    unambiguous.
      #
      # @param source [String] Ruby source code to scan
      # @param via [Symbol] Relationship label (default: :code_reference)
      # @return [Array<Hash>] Dependency hashes with :type, :target, :via
      def scan_model_dependencies(source, via: :code_reference)
        # Strip `#` line comments before scanning so references inside
        # YARD docstrings / TODO comments don't generate ghost edges.
        # Applied to ALL passes — a commented `Library::Book` previously
        # still produced an edge through the full-name pass, which the
        # stripping was added to prevent. The negative lookahead `(?!\{)`
        # keeps Ruby's `#{...}` string interpolation intact — stripping
        # blindly would eat every model reference inside
        # `"Book: #{Library::Book.new}"` etc., which is a common
        # ERB/Phlex/string pattern.
        scannable = source.gsub(/#(?!\{)[^\n]*/, '')

        targets = Set.new
        scannable.scan(ModelNameCache.model_names_regex).each { |m| targets << m }
        extract_constantize_targets(scannable).each { |t| targets << t }

        # Short-name + constantize resolution are additive passes guarded
        # by `respond_to?` so partial test doubles that only stub
        # `model_names_regex` still work. Real extraction runs always
        # have the full API.
        if ModelNameCache.respond_to?(:short_names_regex) && ModelNameCache.respond_to?(:resolve_short_name)
          scannable.scan(ModelNameCache.short_names_regex).each do |short|
            resolved = ModelNameCache.resolve_short_name(short)
            targets << resolved if resolved
          end
        end

        targets.map { |model_name| { type: :model, target: model_name, via: via } }
      end

      # Extract string-literal arguments passed to `.constantize` or
      # `const_get(...)`. Matches both `"Library::Book".constantize`
      # and `Object.const_get("Library::Book")` / `const_get("...")`.
      # Only returns names actually present in {ModelNameCache.model_names}
      # so non-model uses (e.g. `"String".constantize` in infra code) do
      # not produce ghost edges.
      #
      # @param source [String]
      # @return [Array<String>]
      def extract_constantize_targets(source)
        return [] unless ModelNameCache.respond_to?(:model_names)

        known = ModelNameCache.model_names.to_set
        return [] if known.empty?

        targets = []
        source.scan(/(["'])([A-Z][\w:]*)\1\s*\.\s*constantize\b/) do |_quote, name|
          targets << name if known.include?(name)
        end
        source.scan(/const_get\s*\(\s*(["'])([A-Z][\w:]*)\1/) do |_quote, name|
          targets << name if known.include?(name)
        end
        targets
      end

      # Scan for service object references (e.g., FooService.call, FooService::new).
      #
      # @param source [String] Ruby source code to scan
      # @param via [Symbol] Relationship label (default: :code_reference)
      # @return [Array<Hash>] Dependency hashes
      def scan_service_dependencies(source, via: :code_reference)
        source.scan(/(\w+Service)(?:\.|::)/).flatten.uniq.map do |service|
          { type: :service, target: service, via: via }
        end
      end

      # Scan for background job references (e.g., FooJob.perform_later).
      #
      # @param source [String] Ruby source code to scan
      # @param via [Symbol] Relationship label (default: :code_reference)
      # @return [Array<Hash>] Dependency hashes
      def scan_job_dependencies(source, via: :code_reference)
        source.scan(/(\w+Job)\.perform/).flatten.uniq.map do |job|
          { type: :job, target: job, via: via }
        end
      end

      # Scan for mailer references (e.g., UserMailer.welcome_email).
      #
      # @param source [String] Ruby source code to scan
      # @param via [Symbol] Relationship label (default: :code_reference)
      # @return [Array<Hash>] Dependency hashes
      def scan_mailer_dependencies(source, via: :code_reference)
        source.scan(/(\w+Mailer)\./).flatten.uniq.map do |mailer|
          { type: :mailer, target: mailer, via: via }
        end
      end

      # Scan for all common dependency types and return a deduplicated array.
      #
      # Combines model, service, job, and mailer scans. Use this when an
      # extractor needs all four standard dependency types with the default
      # +:code_reference+ via label.
      #
      # @param source [String] Ruby source code to scan
      # @return [Array<Hash>] Deduplicated dependency hashes
      def scan_common_dependencies(source)
        deps = []
        deps.concat(scan_model_dependencies(source))
        deps.concat(scan_service_dependencies(source))
        deps.concat(scan_job_dependencies(source))
        deps.concat(scan_mailer_dependencies(source))
        deps.uniq { |d| [d[:type], d[:target]] }
      end

      # Match _path/_url route helpers anywhere in source.
      # This intentionally matches all usages (assignments, string interpolation, etc.)
      # not just link_to/redirect_to calls — any reference to a route helper indicates
      # a dependency on that controller. False positives from non-route _path/_url
      # suffixes (file_path, base_url, etc.) are filtered by RouteHelperResolver::IGNORED_HELPER_PREFIXES.
      # Requires the including class to also include RouteHelperResolver
      # and call build_route_helper_map in its initializer.
      ROUTE_HELPER_PATTERN = /\b(\w+)_(path|url)\b/

      # Match form_with/form_for with a named route helper as the action/url.
      # Scans only within the form opening tag (up to the first `do`, `%>`, or `end`)
      # to avoid matching unrelated _path/_url helpers that appear after the form.
      FORM_ACTION_HELPER = /form_(with|for)\b[^%]*?(\w+)_(path|url)/

      # Scan source for named route helpers and resolve them to controller targets.
      #
      # Gated by +Woods.configuration.extract_navigation_edges+.
      # Requires {RouteHelperResolver} to be included and initialized.
      #
      # @param source [String] Ruby/ERB/HAML source code to scan
      # @param via_type [Symbol] Relationship label (default: :link_to)
      # @return [Array<Hash>] Dependency hashes with :type, :target, :via
      def scan_navigation_dependencies(source, via_type: :link_to)
        return [] unless Woods.configuration&.extract_navigation_edges

        seen_helpers = Set.new
        seen_targets = Set.new
        deps = []
        source.scan(ROUTE_HELPER_PATTERN).each do |route_name, suffix|
          helper = "#{route_name}_#{suffix}"
          next if seen_helpers.include?(helper)

          seen_helpers.add(helper)
          resolved = resolve_route_helper(helper)
          next unless resolved

          target = resolved[:controller]
          next if seen_targets.include?(target)

          seen_targets.add(target)
          deps << { type: :controller, target: target, via: via_type }
        end
        deps
      end

      # Scan source for form_with/form_for calls targeting named route helpers.
      #
      # Gated by +Woods.configuration.extract_navigation_edges+.
      # Requires {RouteHelperResolver} to be included and initialized.
      #
      # @param source [String] Template/Ruby source code
      # @return [Array<Hash>] Dependency hashes with via: :form_action
      def scan_form_dependencies(source)
        return [] unless Woods.configuration&.extract_navigation_edges

        seen = Set.new
        deps = []
        source.scan(FORM_ACTION_HELPER).each do |_, route_name, suffix|
          resolved = resolve_route_helper("#{route_name}_#{suffix}")
          next unless resolved

          target = resolved[:controller]
          next if seen.include?(target)

          seen.add(target)
          deps << { type: :controller, target: target, via: :form_action }
        end
        deps
      end
    end
  end
end
