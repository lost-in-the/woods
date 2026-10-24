# frozen_string_literal: true

require 'set'
require_relative '../model_name_cache'
require_relative 'comment_blanking'
require_relative 'reference_patterns'
require_relative 'form_action_scan'
require_relative 'route_helper_resolver'
require_relative 'config_read_scanner'

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
    #       consolidate_dependencies(deps)
    #     end
    #   end
    #
    module SharedDependencyScanner
      include ConfigReadScanner

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
        # Comments and heredoc text are blanked before every pass, so a model
        # named only in a YARD docstring, a TODO, a `=begin` block, or the
        # prose of a heredoc produces no edge. A `#` in a quoted string or
        # an interpolation is code: `link_to "Tag #ruby", Article.recent`
        # keeps its `Article` reference.
        scannable = CommentBlanking.ruby(source)

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
      # A leading `::` names the same constant and is not part of the target.
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
        source.scan(/(["'])(?:::)?([A-Z][\w:]*+)\1\s*\.\s*constantize\b/) do |_quote, name|
          targets << name if known.include?(name)
        end
        source.scan(/const_get\s*\(\s*(["'])(?:::)?([A-Z][\w:]*+)\1/) do |_quote, name|
          targets << name if known.include?(name)
        end
        targets
      end

      # Scan for service object references (e.g., FooService.call, FooService::new).
      #
      # Targets keep their namespace ({ReferencePatterns.service_references}):
      # `Billing::ChargeService.call` records the fully-qualified name the
      # service's own unit is identified by.
      #
      # @param source [String] Ruby source code to scan
      # @param via [Symbol] Relationship label (default: :code_reference)
      # @return [Array<Hash>] Dependency hashes
      def scan_service_dependencies(source, via: :code_reference)
        ReferencePatterns.service_references(source).uniq.map do |service|
          { type: :service, target: service, via: via }
        end
      end

      # Scan for background job references (e.g., FooJob.perform_later,
      # HardWorker.perform_async, SyncJob.set(wait: 5).perform_later).
      #
      # Every match is an enqueue, so each job also gets a +:job_enqueue+
      # edge beside the +via+ one: whichever unit enqueues (a model, a
      # controller, another job) records the enqueue the same way.
      #
      # @param source [String] Ruby source code to scan
      # @param via [Symbol] Relationship label (default: :code_reference)
      # @return [Array<Hash>] Dependency hashes
      def scan_job_dependencies(source, via: :code_reference)
        ReferencePatterns.job_enqueues(source).uniq.flat_map do |job|
          [via, :job_enqueue].uniq.map { |label| { type: :job, target: job, via: label } }
        end
      end

      # Scan for mailer references (e.g., UserMailer.welcome_email).
      #
      # @param source [String] Ruby source code to scan
      # @param via [Symbol] Relationship label (default: :code_reference)
      # @return [Array<Hash>] Dependency hashes
      def scan_mailer_dependencies(source, via: :code_reference)
        ReferencePatterns.mailer_references(source).uniq.map do |mailer|
          { type: :mailer, target: mailer, via: via }
        end
      end

      # Scan for all common dependency types and return a deduplicated array.
      #
      # Combines model, service, job, and mailer scans, plus configuration file
      # reads ({ConfigReadScanner}). Use this when an extractor needs the
      # standard dependency types with their default via labels.
      #
      # @param source [String] Ruby source code to scan
      # @return [Array<Hash>] Deduplicated dependency hashes
      def scan_common_dependencies(source)
        consolidate_dependencies(
          scan_model_dependencies(source),
          scan_service_dependencies(source),
          scan_job_dependencies(source),
          scan_mailer_dependencies(source),
          scan_config_dependencies(source)
        )
      end

      # Merge dependency arrays and deduplicate by +[type, target]+.
      #
      # Centralizes the `deps.uniq { |d| [d[:type], d[:target]] }` chain
      # duplicated at the end of most extractors' +extract_dependencies+
      # methods. Arrays are flattened one level and nils removed; the first
      # occurrence of each +[type, target]+ pair wins, so the first +:via+
      # label recorded is preserved — identical to the inline chains this
      # replaces. A +:job_enqueue+ edge is the exception: it is kept beside
      # the first edge to the same job, so an enqueue stays visible to
      # readers that follow enqueue edges.
      #
      # @param dependency_arrays [Array<Array<Hash>>] One or more dependency arrays
      # @return [Array<Hash>] Flattened, nil-free, deduplicated dependency hashes
      def consolidate_dependencies(*dependency_arrays)
        dependency_arrays.flatten(1).compact.uniq { |d| [d[:type], d[:target], d[:via] == :job_enqueue] }
      end

      # Match _path/_url route helpers anywhere in source.
      # This intentionally matches all usages (assignments, string interpolation, etc.)
      # not just link_to/redirect_to calls — any reference to a route helper indicates
      # a dependency on that controller. RouteHelperResolver accepts only names
      # present in the live controller/action route map, excluding unknown helpers.
      # Requires the including class to also include RouteHelperResolver
      # and call build_route_helper_map in its initializer.
      ROUTE_HELPER_PATTERN = /\b(\w+)_(path|url)\b/

      # {ROUTE_HELPER_PATTERN}, except a keyword label (`base_url: host`):
      # a label names an argument, not a helper. `posts_path::X` is no label.
      # A shorthand keyword with no value (`t('.x', posts_path:)`, ended by
      # `,`, `)`, or `}`) passes the helper's result, so it is a call.
      ROUTE_HELPER_CALL = /\b(\w+)_(path|url)\b(?!:(?!:|\s*+[,)}]))/

      # A method the source defines under a helper-shaped name
      # (`def tracking_url`). Its calls are calls to that method.
      ROUTE_HELPER_SHAPED_DEF = /\bdef[ \t]++(?:self\.)?(\w+_(?:path|url))\b/

      # Where a form_with/form_for call's arguments end: the first `do`, `%>`,
      # or `end`, so an unrelated _path/_url helper after the form is not
      # taken as its action. A `%` alone cannot bound plain-Ruby sources
      # (Phlex, ViewComponent, mailers), where a `form_with` with no
      # route-helper argument would run past its own `do` block into the
      # next `_path` call in the method. See {FormActionScan}.
      FORM_SPAN_STOP = /%>|\bdo\b|\bend\b/

      # Scan source for named route helpers and resolve them to controller targets.
      #
      # Gated by +Woods.configuration.extract_navigation_edges+.
      # Requires {RouteHelperResolver} to be included and initialized.
      #
      # @param source [String] Ruby source code to scan; its comments are not read
      # @param via_type [Symbol] Relationship label (default: :link_to)
      # @return [Array<Hash>] Dependency hashes with :type, :target, :via
      def scan_navigation_dependencies(source, via_type: :link_to)
        return [] unless Woods.configuration&.extract_navigation_edges

        navigation_route_helpers(source).map { |_helper, resolved| resolved[:controller] }.uniq.map do |target|
          { type: :controller, target: target, via: via_type }
        end
      end

      # Scan source for form_with/form_for calls targeting named route helpers.
      #
      # Gated by +Woods.configuration.extract_navigation_edges+.
      # Requires {RouteHelperResolver} to be included and initialized.
      #
      # @param source [String] Ruby source code; its comments are not read
      # @return [Array<Hash>] Dependency hashes with via: :form_action
      def scan_form_dependencies(source)
        return [] unless Woods.configuration&.extract_navigation_edges

        form_route_helpers(source).map { |_helper, resolved| resolved[:controller] }.uniq.map do |target|
          { type: :controller, target: target, via: :form_action }
        end
      end

      # Every route helper the source calls, resolved (woods#795): the same
      # helpers {#scan_navigation_dependencies} and {#scan_form_dependencies}
      # reduce to one edge per controller, each kept with its named route,
      # action, verb and path.
      #
      # @param source [String] Ruby source code; its comments are not read
      # @param via_type [Symbol] the label of a plain helper call
      # @param forms [Boolean] whether form_with/form_for actions are read
      # @return [Array<Hash>, nil] {RouteHelperResolver#route_helper_reference}
      #   hashes, or nil when navigation edges are off
      def scan_route_helper_references(source, via_type: :link_to, forms: true)
        return nil unless Woods.configuration&.extract_navigation_edges

        references = navigation_route_helpers(source).map do |helper, resolved|
          route_helper_reference(helper, resolved, via_type)
        end
        if forms
          references.concat(form_route_helpers(source).map do |helper, resolved|
            route_helper_reference(helper, resolved, :form_action)
          end)
        end
        collate_route_helper_references(references)
      end

      # Set +metadata[:route_helper_references]+ from the unit's source;
      # leave it absent when navigation edges are off.
      #
      # @param unit [ExtractedUnit]
      # @param source [String]
      # @return [void]
      def apply_route_helper_references(unit, source, **options)
        references = scan_route_helper_references(source.to_s, **options)
        unit.metadata[:route_helper_references] = references if references
      end

      private

      # @return [Array<Array(String, Hash)>] each distinct helper call the
      #   source makes that names a live route, with its resolution
      def navigation_route_helpers(source)
        source = CommentBlanking.ruby(source)
        seen_helpers = source.scan(ROUTE_HELPER_SHAPED_DEF).flatten.to_set
        source.scan(ROUTE_HELPER_CALL).filter_map do |route_name, suffix|
          helper = "#{route_name}_#{suffix}"
          next if seen_helpers.include?(helper)

          seen_helpers.add(helper)
          resolved = resolve_route_helper(helper)
          [helper, resolved] if resolved
        end
      end

      # @return [Array<Array(String, Hash)>] each form action helper that
      #   names a live route, with its resolution
      def form_route_helpers(source)
        FormActionScan.route_helpers(CommentBlanking.ruby(source), stop: FORM_SPAN_STOP).filter_map do |route_name, suffix|
          helper = "#{route_name}_#{suffix}"
          resolved = resolve_route_helper(helper)
          [helper, resolved] if resolved
        end
      end
    end
  end
end
