# frozen_string_literal: true

require 'prism'
require_relative '../source_file'
require_relative 'action_facts'

module Woods
  module Extractors
    # Per-action facts for a controller or mailer class (W-7, woods#757).
    #
    # For each action: the facts {ActionFacts} reads from the action's own
    # body, plus the assigns, params, redirects and renders of every before
    # or around filter whose declared +only+/+except+ names the action. Each
    # fact is attributed to the method and file it was read from, so an
    # instance variable a parent controller's filter assigns reads as that
    # filter's, at that file's line. A filter given as a proc, a filter whose
    # body lives outside the application, and an +if:+/+unless+ condition are
    # not evaluated: the facts are what the source declares.
    #
    # Including classes provide +extract_callback_conditions+ (from
    # {SharedUtilityMethods}); a class that defines +app_action_source?+ uses
    # it to keep gem-installed bodies out.
    module ActionFactResolution
      FILTER_KINDS = %i[before around].freeze
      FACT_KINDS = %i[assigns params redirects].freeze

      # @param klass [Class] a controller or mailer class
      # @param actions [Array<String, Symbol>] the actions to read
      # @param view_prefix [String] the class's view path, e.g. +users+ or +user_mailer+
      # @param permitted [Hash{String => String}] permitted-params method => model key
      # @param mailer [Boolean]
      # @return [Hash{String => Hash}] action => +file+, +line+, +assigns+,
      #   +params+, +renders+, +redirects+, +formats+; an action whose body
      #   is not application source is absent
      def resolve_action_facts(klass, actions, view_prefix:, permitted: {}, mailer: false)
        options = { view_prefix: view_prefix, permitted: permitted, mailer: mailer }
        actions.each_with_object({}) do |action, all|
          facts = facts_for_action(klass, action.to_s, options)
          all[action.to_s] = facts if facts
        end
      end

      private

      def facts_for_action(klass, action, options)
        file, line = fact_method_location(klass, action)
        own = file && scan_fact_definition(file, action, line, options)
        return nil unless own

        entry = { file: fact_path(file), line: line, assigns: [], params: [], renders: [], redirects: [],
                  formats: own[:formats] }
        fact_filters(klass, action).each { |name| add_filter_facts(entry, klass, name, options) }
        attribute(entry, own, action, file)
        entry
      end

      def add_filter_facts(entry, klass, name, options)
        file, line = fact_method_location(klass, name)
        facts = file && scan_fact_definition(file, name, line, options.merge(implicit: false))
        attribute(entry, facts, name, file) if facts
      end

      def attribute(entry, facts, method, file)
        attribution = { method: method, file: fact_path(file) }
        FACT_KINDS.each { |kind| entry[kind].concat(facts[kind].map { |fact| fact.merge(attribution) }) }
        entry[:renders].concat(facts[:renders].map do |fact|
          fact[:implicit] ? fact.merge(method: method) : fact.merge(attribution)
        end)
      end

      # The symbol filters that run before the action, in chain order, whose
      # declared only/except names it.
      def fact_filters(klass, action)
        return [] unless klass.respond_to?(:_process_action_callbacks)

        klass._process_action_callbacks.to_a.filter_map do |callback|
          next unless FILTER_KINDS.include?(callback.kind)

          filter = callback.respond_to?(:raw_filter) ? callback.raw_filter : callback.filter
          next unless filter.is_a?(Symbol) || filter.is_a?(String)

          only, except = extract_callback_conditions(callback)
          next if only.any? && !only.include?(action)
          next if except.include?(action)

          filter.to_s
        end.uniq
      end

      def fact_method_location(klass, name)
        file, line = klass.instance_method(name).source_location
        fact_source?(file) ? [file, line] : nil
      rescue NameError
        nil
      end

      def fact_source?(file)
        return false unless file && File.exist?(file)
        return app_action_source?(file) if respond_to?(:app_action_source?, true)

        app_source?(file, Rails.root.to_s)
      end

      def scan_fact_definition(file, name, line, options)
        node = ActionFacts.definition(fact_program(file), name, line)
        node && ActionFacts.scan(node, **options)
      end

      # One parse per file per extractor instance, like the action-source cache.
      def fact_program(file)
        (@fact_programs ||= {})[file] ||= Prism.parse(SourceFile.read(file)).value
      end

      def fact_path(file)
        File.expand_path(file).delete_prefix("#{File.expand_path(Rails.root.to_s)}#{File::SEPARATOR}")
      end
    end
  end
end
