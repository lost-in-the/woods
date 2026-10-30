# frozen_string_literal: true

module Woods
  # Resolves the constant names the static self-map's units reference, as
  # written, to the classes and modules the map defines (#926). Names that
  # name no definition (stdlib, gems, dynamic constants) stay as written.
  #
  # Resolution follows Ruby's lexical lookup: a reference tries each
  # enclosing scope, innermost first, then the top level. A method sees the
  # scopes of its owner's definition in the same file; a unit with no
  # scopes (top-level scripts, specs) resolves absolute names only.
  class GemMapQualifier
    DEFINITION_TYPES = %i[ruby_class ruby_module].freeze
    private_constant :DEFINITION_TYPES

    # @param units [Array<ExtractedUnit>] every unit of one map build
    def initialize(units)
      @units = units
      @definitions = units.select { |unit| DEFINITION_TYPES.include?(unit.type) }.to_h do |unit|
        [canonical(unit), unit]
      end
      @owner_scopes = owner_scopes
    end

    # Rewrite each resolvable dependency's target and type in place.
    #
    # @return [void]
    def qualify!
      @units.each do |unit|
        scopes = Array(unit.metadata[:lexical_scopes] || @owner_scopes[[unit.namespace, unit.file_path]])
        unit.dependencies.each { |dependency| qualify(dependency, scopes) }
      end
    end

    private

    def canonical(unit)
      unit.metadata[:canonical_identifier] || unit.identifier
    end

    # A method unit carries no nesting of its own: it is written inside the
    # body of its owner, so it sees the owner's lexical scopes from that file.
    def owner_scopes
      @units.each_with_object({}) do |unit, scopes|
        next unless DEFINITION_TYPES.include?(unit.type)

        scopes[[canonical(unit), unit.file_path]] ||= unit.metadata[:lexical_scopes]
      end
    end

    def qualify(dependency, scopes)
      target = dependency[:target]
      return unless target.is_a?(String)

      scopes = scopes.drop(1) if dependency[:via] == :inheritance
      resolved = candidates(target, scopes).find { |candidate| @definitions.key?(candidate) }
      resolved ||= defined_prefix(target) if dependency[:via] == :reference
      return unless resolved

      dependency[:target] = resolved
      dependency[:type] = @definitions[resolved].type
    end

    def candidates(target, scopes)
      return [target.delete_prefix('::')] if target.start_with?('::')

      scopes.map { |scope| "#{scope}::#{target}" } + [target]
    end

    # A spec naming `Woods::Extractor::EXTRACTORS` depends on the class that
    # defines the constant. Prefixes shorter than two segments are namespaces.
    def defined_prefix(target)
      segments = target.split('::')
      prefixes = (segments.size - 1).downto(2).map { |size| segments.first(size).join('::') }
      prefixes.find { |candidate| @definitions.key?(candidate) }
    end
  end
end
