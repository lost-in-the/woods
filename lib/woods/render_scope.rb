# frozen_string_literal: true

require_relative 'extractors/constant_footprint'
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
    # Paths outside an `app/` directory (lib, config, vendored code) define
    # constants the published units do not hold, so an edit there is unreadable.
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
      reaches?(%i[component view_component])
    end

    # @return [Boolean] whether controller render edges can have moved
    def controllers?
      reaches?(%i[controller])
    end

    private

    def reaches?(types)
      touched = touched_names
      return true if touched.nil?
      return false if touched.empty?

      !touched.disjoint?(resolved_names(types))
    rescue StandardError, ScriptError
      true
    end

    # @return [Set<String>, nil] nil when an edit cannot be read
    def touched_names
      return @touched_names if defined?(@touched_names)

      @touched_names = compute_touched_names
    end

    def compute_touched_names
      paths = @change_set.absolute_paths.select { |path| path.end_with?('.rb') }
      paths.each_with_object(Set.new) do |path, touched|
        return nil unless @change_set.relativize(path).match?(APP_PATH)

        names = Extractors::ConstantFootprint.touched_names(footprint_before(path), footprint_after(path),
                                                            existing: method(:defined_before?))
        return nil if names.nil?

        touched.merge(names)
      end
    rescue StandardError, ScriptError
      nil
    end

    # A name the units of the graph before the edit are nested under (or are).
    def defined_before?(name)
      @namespaces ||= @graph.typed_identifiers.each_with_object(Set.new) do |(_type, identifier), names|
        segments = identifier.split('::')
        segments.each_index { |index| names.add(segments[0..index].join('::')) }
      end
      @namespaces.include?(name)
    end

    def footprint_after(path)
      return EMPTY unless File.file?(path)

      Extractors::ConstantFootprint.call(File.binread(path).force_encoding(Encoding::UTF_8))
    end

    def footprint_before(path)
      relative = @change_set.relativize(path)
      sources = @graph.units_for_path(path).filter_map do |identifier, type|
        unit = @read_unit.call(identifier, type)
        unit && source_of(unit, relative)
      end
      sources.map { |source| Extractors::ConstantFootprint.call(source) }.reduce(EMPTY) { |sum, print| merge(sum, print) }
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
      names = @units_of.call(types).flat_map { |unit| unit_names(unit) }
      names.concat(Array(@ancestor_names.call(types)))
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
