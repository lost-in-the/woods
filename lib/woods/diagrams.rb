# frozen_string_literal: true

require 'json'
require_relative 'diagrams/source'
require_relative 'diagrams/cache'
require_relative 'diagrams/neighbourhood'
require_relative 'diagrams/schema'
require_relative 'diagrams/lifecycle'
require_relative 'diagrams/impact'

module Woods
  # Mermaid text for one unit, built on demand from one pinned published
  # generation (woods#826): its dependency neighbourhood, its schema, its
  # lifecycle and its change impact. The builders read only the published
  # index (units, `dependency_graph.json`, `graph_analysis.json` and the flow
  # data assembled from published units), never the host application, and
  # nothing is computed at extraction. Results are cached per generation.
  #
  # Every kind takes a `depth` whose meaning, default and maximum are its own
  # ({DEPTHS}). A diagram over its kind's budget is refused with the reason
  # and never truncated, so a caller can retry with a smaller depth or
  # narrower filters. Woods Map draws the same text from these builders.
  module Diagrams
    # A request the builders cannot answer: an unknown kind, a depth out of
    # range, a kind that does not apply to the unit's type.
    class InvalidRequest < ArgumentError; end

    # The named unit is not in the pinned generation.
    class UnitNotFound < StandardError; end

    # One diagram: its Mermaid text, or the refusal that replaced it (never
    # both), the generation it was built from, and what was built.
    #
    # @!attribute text [String, nil] Mermaid text, no trailing newline
    # @!attribute refusal [String, nil] why nothing is drawn: the size over the budget
    # @!attribute generation [Integer] the published generation number (0 for a flat index)
    # @!attribute details [Hash] string-keyed: kind, identifier, type, depth, budget, size and kind options
    Result = Struct.new(:text, :refusal, :generation, :details, keyword_init: true) do
      # @return [Boolean] whether a diagram was drawn
      def drawn?
        !text.nil?
      end
    end

    # Each kind's depth: what it counts, its default and the range accepted.
    DEPTHS = {
      'neighbourhood' => { default: 1, range: 1..3, meaning: 'graph hops from the unit' },
      'schema' => { default: 1, range: 1..3, meaning: 'association hops from the model\'s table' },
      'lifecycle' => { default: 0, range: 0..2,
                       meaning: '0 is the model event\'s own callback chain; 1 and 2 follow the async hops ' \
                                '(perform_later, deliver_later) into the jobs and mailers the chain reaches' },
      'impact' => { default: 2, range: 0..10, meaning: 'reverse dependency hops of the change impact report' }
    }.freeze

    KINDS = DEPTHS.keys.freeze

    BUILDERS = { 'neighbourhood' => Neighbourhood, 'schema' => Schema, 'lifecycle' => Lifecycle,
                 'impact' => Impact }.freeze
    private_constant :BUILDERS

    module_function

    # Build (or read from the per-generation cache) one diagram.
    #
    # @param reader [Woods::MCP::IndexReader] the reader of the published index
    # @param kind [String] one of {KINDS}
    # @param identifier [String] the unit's identifier
    # @param index_dir [String, Pathname, nil] the index root, for the impact kind
    # @param options [Hash] `type` (the unit type; the graph's primary node when nil), `depth` (the
    #   kind's depth; its default when nil) and the kind's own: `direction`, `types` and `via`
    #   (neighbourhood), `event` (lifecycle)
    # @return [Result]
    # @raise [InvalidRequest] for a kind, depth or option the builders do not accept
    # @raise [UnitNotFound] when the generation has no such unit
    def build(reader, kind:, identifier:, index_dir: nil, **options)
      kind = kind.to_s
      raise InvalidRequest, "Unknown diagram kind #{kind.inspect}; use one of #{KINDS.join(', ')}" unless
        KINDS.include?(kind)

      type = options.delete(:type)&.to_s
      depth = depth_for(kind, options.delete(:depth))
      reader.with_pinned_generation do
        source = Source.new(reader, index_dir: index_dir)
        key = [source.cache_identity, kind, identifier.to_s, type, depth, options.sort_by { |k, _| k.to_s }]
        Cache.fetch(key) do
          BUILDERS.fetch(kind).new(source, identifier: identifier.to_s, type: type, depth: depth, **options).result
        end
      end
    end

    # @param kind [String]
    # @return [Array<Symbol>] the options the kind takes besides type and depth; none for an unknown kind
    def options_for(kind)
      builder = BUILDERS[kind.to_s]
      builder ? builder::OPTIONS.map(&:to_sym) : []
    end

    # @param kind [String]
    # @param depth [Integer, String, nil]
    # @return [Integer] the depth, the kind's default when nil
    # @raise [InvalidRequest] when outside the kind's range
    def depth_for(kind, depth)
      spec = DEPTHS.fetch(kind)
      return spec[:default] if depth.nil?

      value = Integer(depth, exception: false)
      return value if value && spec[:range].cover?(value)

      raise InvalidRequest, "#{kind} depth must be #{spec[:range].min} to #{spec[:range].max} " \
                            "(#{spec[:meaning]}); got #{depth.inspect}"
    end
  end
end
