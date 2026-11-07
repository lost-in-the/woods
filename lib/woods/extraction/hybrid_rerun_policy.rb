# frozen_string_literal: true

require 'set'
require_relative '../source_file'

module Woods
  module Extraction
    # Whether a Ruby edit has to re-extract a hybrid family (jobs,
    # serializers: {Extractor::HYBRID_DISCOVERY_EXTRACTORS}) whole.
    #
    # Their runtime metadata can read Ruby outside the unit's own file and
    # its graph edges (`queue_as Settings::QUEUE`), so any Ruby edit used to
    # refresh both complete inventories. The published source-reference
    # baseline names every constant each unit's sources spell, so the family
    # is refreshed whole only when a changed file could have changed what one
    # of those names means: it is a source of a family unit (a definition,
    # removal or rename), it declares, before or after the edit, a constant a
    # family unit names (through its lexical nesting and every prefix of the
    # constant path), or it carries a construct that defines constants or
    # methods by other means than a declaration. The family's own sources
    # come from the graph, so a class-discovered unit counts by the file that
    # declares it, and the runtime inventory is read after the reload: a
    # discovered class the graph does not know (a new descendant, a generated
    # worker) refreshes the family whole, whatever file produced it. Without
    # a baseline, with incomplete discovery, or for a family source the
    # baseline never analysed, the family is refreshed whole as before. A
    # family unit a changed file reaches through a graph edge is re-extracted
    # on its own by the blast radius.
    #
    # The one shape this cannot see is a constant a changed file creates
    # without any of the markers below, without declaring it and without a
    # family class appearing: a family unit whose runtime facts read it keeps
    # them until the next full extraction or its own change.
    class HybridRerunPolicy
      # Constructs that define constants or methods without a declaration
      # the collector records.
      MARKERS = /
        \b(?:const_set|const_get|remove_const|constantize|safe_constantize|define_method|define_singleton_method|
           class_eval|module_eval|instance_eval|class_exec|module_exec|instance_exec|method_missing|const_missing|
           autoload)\b
        |\b(?:Class|Module|Struct|Data)\.new\b
      /x

      Decision = Struct.new(:wholesale, :reason, keyword_init: true) do
        def wholesale? = wholesale
      end

      # @param baseline [Hash, nil] the published source-reference cache
      #   ({SourceReferences::Cache}), nil when the index has none
      # @param root [String, Pathname] application root
      # @param collector [#call] source-only analysis of one Ruby source, as
      #   {SourceReferences::Collector#call} answers it
      def initialize(baseline:, root:, collector:)
        @baseline = baseline
        @root = root.to_s
        @collector = collector
      end

      # @param key [Symbol] the family's extractor key, for the reason only
      # @param change_set [ChangeSet]
      # @param sources [Array<String>] every source path of the family's
      #   units in the pre-change graph, relative to the root
      # @param new_classes [Array<String>, nil] class names the family's
      #   runtime discovery and the graph disagree on, discovered but not
      #   indexed or indexed but no longer discovered; nil when discovery is
      #   incomplete
      # @return [Decision]
      def decide(key, change_set:, sources:, new_classes:)
        files = baseline_files
        return wholesale("#{key}: no source-reference baseline") unless files

        changed = change_set.relative_paths.select { |path| path.end_with?('.rb') }
        inventory(key, new_classes) || own_source(key, sources, changed) || unanalysed(key, files, sources) ||
          forced_by_change(key, files, sources, changed) || narrow(key)
      end

      private

      def baseline_files
        files = @baseline['files'] if @baseline.is_a?(Hash)
        files if files.is_a?(Hash)
      end

      # Runtime discovery that is incomplete, or disagrees with the graph on
      # a class, forces a refresh before any file is looked at.
      def inventory(key, new_classes)
        return wholesale("#{key}: runtime discovery is incomplete") if new_classes.nil?

        wholesale("#{key}: runtime discovery of #{new_classes.first} differs from the index") unless new_classes.empty?
      end

      def wholesale(reason)
        Decision.new(wholesale: true, reason: reason)
      end

      def narrow(key)
        Decision.new(wholesale: false, reason: "#{key}: no changed file declares a constant its units name; " \
                                               'units in the blast radius are re-extracted on their own')
      end

      def own_source(key, sources, changed)
        owned = (sources & changed).first
        wholesale("#{key}: changed source #{owned} is one of its own") if owned
      end

      def unanalysed(key, files, sources)
        missing = sources.find { |path| files[path]&.dig('analysis').nil? }
        wholesale("#{key}: a source of its own, #{missing}, was never analysed") if missing
      end

      def forced_by_change(key, files, sources, changed)
        named = referenced_names(sources.map { |path| files[path]['analysis'] })
        changed.lazy.filter_map { |path| decide_path(key, path, files[path], named) }.first
      end

      # Every constant path a family source could resolve a reference to:
      # the spelling as written, each prefix of it, and each of those under
      # every lexical scope open at the reference.
      #
      # @return [Set<String>]
      def referenced_names(analyses)
        analyses.each_with_object(Set.new) do |analysis, names|
          Array(analysis['references']).each { |reference| candidate_names(reference, names) }
        end
      end

      def candidate_names(reference, names)
        spelled = reference['name'].to_s
        return if spelled.empty?

        bases = spelled.start_with?('::') ? [''] : [''] + Array(reference['nesting']).map { |scope| "#{scope}::" }
        segments = spelled.delete_prefix('::').split('::')
        bases.each do |base|
          segments.size.times { |count| names << "#{base}#{segments.first(count + 1).join('::')}" }
        end
      end

      # The decision one changed file forces, or nil when it forces none.
      def decide_path(key, path, record, named)
        before = declared_owners(record&.dig('analysis'))
        after, forced = current_declarations(key, path)
        return forced if forced

        declared = (before + after).find { |owner| named.include?(owner) }
        wholesale("#{key}: #{path} declares #{declared}, which a unit names") if declared
      end

      # The constants the file declares as it is now, or the decision its
      # text forces: a defining construct the collector cannot see, a parse
      # error, or an unreadable file. A deleted file declares nothing now.
      #
      # @return [Array(Array<String>, Decision)]
      def current_declarations(key, path)
        absolute = File.join(@root, path)
        return [[], nil] unless File.file?(absolute)

        source = SourceFile.read(absolute)
        marker = source[MARKERS]
        return [[], wholesale("#{key}: #{path} defines by #{marker.strip}")] if marker

        analysis = @collector.call(source)
        return [[], wholesale("#{key}: #{path} does not parse")] if analysis['parse_error']

        [declared_owners(analysis), nil]
      rescue SystemCallError, EncodingError, ArgumentError => e
        [[], wholesale("#{key}: #{path} could not be read (#{e.class})")]
      end

      def declared_owners(analysis)
        Array(analysis&.dig('declarations')).map { |declaration| declaration['owner'] }
      end
    end
  end
end
