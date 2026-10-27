# frozen_string_literal: true

require 'pathname'

require_relative 'extractors/constant_footprint'
require_relative 'extractors/render_call_scan'
require_relative 'source_contributors'

module Woods
  # Whether an incremental run's Ruby edits can move what a family's render
  # calls resolve to.
  #
  # Component and controller units name the components they render by looking
  # the name up in the loaded constant tables, so an edit anywhere can change
  # an edge of a unit nobody touched: a class that now shadows the one a name
  # reached, an unresolved name that now exists, a Kit that gained a method.
  # The dependency graph holds no edge to walk for that.
  #
  # The answer is exact in the direction that matters. The constants an edit
  # touched are read off the syntax tree of the file before and after
  # ({Extractors::ConstantFootprint}); the names a family resolves are read from
  # its published units (resolved targets, unresolved and external names) and
  # from the ancestors of its classes. A family is reached when the two
  # overlap, and whenever the tree cannot say what an edit touched.
  #
  # The file before the edit is recovered from the published units that
  # recorded it. A part of a file no unit holds is read as new, which can only
  # make an edit look larger.
  class RenderScope
    # Component-family refresh keeps its conservative fallback outside app/.
    # Controllers can narrow library edits with a retained source baseline.
    APP_PATH = %r{(?:\A|/)app/}
    EMPTY = Extractors::ConstantFootprint::Result.new(definitions: {}, opaque: false)

    # @param change_set [ChangeSet]
    # @param graph [DependencyGraph] before the edit
    # @param read_unit [#call] (identifier, type) => published unit Hash, or nil
    # @param units_of [#call] (types) => published unit Hashes of those types
    # @param ancestor_names [#call] (types) => names of the ancestors of the family's classes
    def initialize(change_set:, graph:, read_unit:, units_of:, ancestor_names:)
      @change_set = change_set
      @graph = graph
      @read_unit = read_unit
      @units_of = units_of
      @ancestor_names = ancestor_names
    end

    # @return [Boolean] whether Phlex and ViewComponent edges can have moved
    def components?
      touched = touched_constants(app_only: true)&.to_set { |name| name.split('::').last }
      return true if touched.nil?

      !touched.empty? && !touched.disjoint?(resolved_names(%i[component view_component]))
    rescue StandardError, ScriptError
      true
    end

    # Select published controllers individually. Ancestors retain qualified
    # names: Importers::Base cannot change ActionController::Base's lookup.
    # Unreadable source or unit payloads retain the conservative fallback.
    # @param ancestors_of [#call] (controller identifier) => qualified ancestor names
    # @return [Array<String>] controllers whose render lookup may have changed
    def controller_ids(ancestors_of:)
      ids = @graph.units_of_type(:controller)
      touched = touched_constants(app_only: false)
      return ids if touched.nil?
      return [] if touched.empty?

      leaves = touched.to_set { |name| name.split('::').last }
      ids.select { |id| controller_reached?(id, touched, leaves, ancestors_of) }
    rescue StandardError, ScriptError
      ids
    end

    private

    def touched_constants(app_only:)
      @change_set.absolute_paths.select { |path| path.end_with?('.rb') }.each_with_object(Set.new) do |path, touched|
        return nil unless readable_path?(path, app_only)

        names = Extractors::ConstantFootprint.touched_constants(*footprints(path), existing: method(:defined_before?))
        return nil if names.nil?

        touched.merge(names)
      end
    end

    # A missing library baseline could hide a removed constant.
    def readable_path?(path, app_only)
      relative = @change_set.relativize(path)
      return relative.match?(APP_PATH) if app_only

      !Pathname.new(relative).absolute? && (relative.match?(APP_PATH) || sources_before(path).any?)
    end

    def controller_reached?(id, touched, leaves, ancestors_of)
      unit = @read_unit.call(id, :controller)
      return true unless unit
      return true unless leaves.disjoint?(name_segments(unit_names(unit)))
      return true if Extractors::RenderCallScan.may_render_constants?(unit['source_code'], names: leaves)

      ancestors_of.call(id).any? { |name| touched.include?(name) || touched.include?(name.split('::').last) }
    end

    # A name the units of the graph before the edit are nested under (or are).
    def defined_before?(name)
      @namespaces ||= @graph.typed_identifiers.each_with_object(Set.new) do |(_type, identifier), names|
        segments = identifier.split('::')
        segments.each_index { |index| names.add(segments[0..index].join('::')) }
      end
      @namespaces.include?(name)
    end

    def footprints(path)
      @footprints ||= {}
      @footprints[path] ||= [
        sources_before(path).map { |source| Extractors::ConstantFootprint.call(source) }
                            .reduce(EMPTY) { |sum, print| merge(sum, print) },
        File.file?(path) ? Extractors::ConstantFootprint.call(File.binread(path).force_encoding('UTF-8')) : EMPTY
      ]
    end

    def sources_before(path)
      @sources_before ||= {}
      @sources_before[path] ||= @graph.units_for_path(path).filter_map do |identifier, type|
        unit = @read_unit.call(identifier, type)
        unit && source_of(unit, @change_set.relativize(path))
      end
    end

    # The part of a unit's published source that came from one file.
    def source_of(unit, relative)
      source = unit['source_code'].to_s
      records = SourceContributors.records(unit)
      return source if records.empty?

      record = records.find { |candidate| candidate['file_path'] == relative }
      return nil unless record

      first = record.fetch('published_start_byte')
      source.byteslice(first, record.fetch('published_end_byte') - first)&.force_encoding(Encoding::UTF_8)
    end

    def merge(left, right)
      definitions = left.definitions.merge(right.definitions) { |_name, one, other| (one + other).uniq.sort }
      Extractors::ConstantFootprint::Result.new(definitions: definitions, opaque: left.opaque || right.opaque)
    end

    # Every name segment the family's units resolved or failed to resolve,
    # and every ancestor of its classes.
    def resolved_names(types)
      units = @units_of.call(types)
      name_segments(units.flat_map { |unit| unit_names(unit) } + Array(@ancestor_names.call(types)))
    end

    def name_segments(names)
      names.flat_map { |name| name.to_s.split('::') }.reject(&:empty?).to_set
    end

    def unit_names(unit)
      metadata = unit['metadata'] || {}
      edges = Array(unit['dependencies']).select { |edge| %w[render slot].include?(edge['via'].to_s) }
      listed = %w[unresolved_renders unresolved_slots external_renders].flat_map { |key| Array(metadata[key]) }
      edges.map { |edge| edge['target'] } + listed.map { |entry| entry.is_a?(Hash) ? entry['name'] : entry }
    end
  end
end
