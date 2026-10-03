# frozen_string_literal: true

require 'set'
require_relative 'source_references/runtime_lookup'
require_relative 'extractors/class_families'

module Woods
  # Keeps PORO units equal to a full extraction when ownership changes without
  # the file changing.
  #
  # Owner fallback: owned Ruby under the sweep globs whose owning extractors
  # emit no unit for it (helpers beside a serializer base, a module in a
  # services directory) goes to the PORO path instead of vanishing.
  #
  # The rule is per path and identical in both modes: after typed extraction,
  # a candidate from {Extractors::PoroExtractor#fallback_files} with no unit of
  # any owner's type gets {Extractors::PoroExtractor#extract_fallback_units}.
  # Full extraction reads the run's results; incremental extraction reads the
  # reconciled graph and re-checks every candidate, so hybrid owners replaced
  # wholesale and owners that moved without a path change are both seen.
  module PoroReconciliation
    private

    # Full extraction: add fallback units to the PORO results.
    #
    # @return [void]
    def extract_owner_fallbacks
      poros = @extractors[:poros]
      return unless poros.respond_to?(:fallback_files)

      present = result_types_by_path
      ar_names = fallback_ar_names
      units = poros.fallback_files.flat_map do |path, keys|
        owned = path_spellings(path).any? { |spelling| owner_types(keys).intersect?(present[spelling]) }
        owned ? [] : poros.extract_fallback_units(path, ar_names: ar_names)
      end
      (@results[:poros] ||= []).concat(units)
    end

    # Incremental extraction: bring every candidate's fallback units in line
    # with the reconciled graph.
    #
    # @param affected_types [Set<Symbol>]
    # @return [Set<String>] identifiers written or removed
    def reconcile_owner_fallbacks(affected_types)
      poros = extractor_for(:poros)
      return Set.new unless poros.respond_to?(:fallback_files)

      poros.fallback_files.each_with_object(Set.new) do |(path, keys), touched|
        present = path_spellings(path).flat_map { |spelling| @dependency_graph.units_for_path(spelling) }.uniq
        produced = fallback_units_for(poros, path, keys, present)
        next if produced.nil?

        touched.merge(register_and_write(:poros, produced, affected_types))
        touched.merge(remove_stale_poros(present, produced, affected_types))
      end
    end

    # @return [Array<ExtractedUnit>, nil] nil when the extraction failed
    def fallback_units_for(poros, path, keys, present)
      return [] if present.any? { |_identifier, type| owner_types(keys).include?(type) }

      checked_extraction(:poros, poros) { poros.extract_fallback_units(path, ar_names: active_record_names) }
    end

    def remove_stale_poros(present, produced, affected_types)
      kept = produced.to_set(&:identifier)
      present.each_with_object(Set.new) do |(identifier, type), removed|
        next unless type == :poro && !kept.include?(identifier)

        removed.add(identifier) if remove_unit(identifier, affected_types, type: :poro)
      end
    end

    def result_types_by_path
      @results.each_value.with_object(Hash.new { |hash, path| hash[path] = Set.new }) do |units, present|
        units.each { |unit| path_spellings(unit.file_path).each { |path| present[path].add(unit.type) } }
      end
    end

    # Incremental: a class can join a class-discovered family through another
    # file (a parent gains `include Sidekiq::Job`). Its PORO unit goes, as a
    # full extraction would leave it out.
    #
    # @param affected_types [Set<Symbol>]
    # @return [Set<String>] identifiers removed
    def prune_family_owned_poros(affected_types)
      lookup = SourceReferences::RuntimeLookup.new
      @dependency_graph.units_of_type(:poro).each_with_object(Set.new) do |identifier, touched|
        value = lookup.call("::#{identifier}", allow_private: true)[:value]
        next unless lookup.class_object?(value) && Extractors::ClassFamilies.owner_of(value, lookup)

        touched.add(identifier) if remove_unit(identifier, affected_types, type: :poro)
      end
    end

    # Incremental: a swept file with no unit left can be PORO again after a
    # change elsewhere (a reload drops the job mixin a parent had). Unitless
    # swept files are few, so each run re-extracts all of them.
    #
    # @param affected_types [Set<Symbol>]
    # @return [Set<String>] identifiers written
    def extract_unitless_poro_files(affected_types)
      poros = extractor_for(:poros)
      return Set.new unless poros.respond_to?(:swept_files)

      poros.swept_files.each_with_object(Set.new) do |path, touched|
        next if path_spellings(path).any? { |spelling| @dependency_graph.units_for_path(spelling).any? }

        units = checked_extraction(:poros, poros) { poros.extract_poro_units(path, ar_names: active_record_names) }
        touched.merge(register_and_write(:poros, units, affected_types)) if units
      end
    end

    def owner_types(keys)
      keys.flat_map { |key| self.class::EXTRACTOR_KEY_TO_TYPES.fetch(key, []) }.to_set
    end

    # A runtime-discovered owner can report the realpath of a file the glob
    # named through a symlinked root.
    def path_spellings(path)
      return [] unless path

      expanded = File.expand_path(path.to_s, Rails.root.to_s)
      real = File.exist?(expanded) ? File.realpath(expanded) : expanded
      [expanded, real].uniq
    end

    def fallback_ar_names
      defined?(ActiveRecord::Base) ? ActiveRecord::Base.descendants.filter_map(&:name).to_set : Set.new
    end
  end
end
