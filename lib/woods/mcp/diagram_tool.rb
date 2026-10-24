# frozen_string_literal: true

require_relative '../diagrams'

module Woods
  module MCP
    # The `diagram` tool (woods#826): Mermaid text for one unit from the
    # pinned published generation, built on demand by {Woods::Diagrams} and
    # cached per generation. Always registered: it needs nothing but the index.
    module DiagramTool
      NAME = 'diagram'

      DESCRIPTION = 'Mermaid text of one unit from the published index, built on demand: kind neighbourhood ' \
                    '(typed edges as a flowchart), schema (a model\'s tables as an erDiagram), lifecycle (a model ' \
                    'event\'s callback chain as a sequenceDiagram) or impact (the change impact report\'s ' \
                    'flowchart). Every kind takes depth; a diagram over its budget is refused with its size, ' \
                    'never truncated, so retry with a smaller depth or narrower filters. The text parses with ' \
                    'the Mermaid GitHub renders, so it can go straight into a ```mermaid block in a pull request.'

      class << self
        # @return [Hash] the tool's input schema; depth's meaning per kind is in its description
        def schema
          depth = Woods::Diagrams::DEPTHS.map do |kind, spec|
            "#{kind}: #{spec[:meaning]}, #{spec[:range].min} to #{spec[:range].max}, default #{spec[:default]}"
          end
          names = { type: 'array', items: { type: 'string' } }
          { properties: {
              kind: { type: 'string', enum: Woods::Diagrams::KINDS, description: 'What to draw.' },
              identifier: { type: 'string', minLength: 1, description: 'The unit\'s exact identifier.' },
              type: { type: 'string', description: 'The unit type; the primary graph node when omitted.' },
              depth: { type: 'integer', description: "Per kind. #{depth.join('. ')}." },
              direction: { type: 'string', enum: Woods::Diagrams::Neighbourhood::DIRECTIONS,
                           description: 'neighbourhood only: both (default), dependents or dependencies.' },
              types: names.merge(description: 'neighbourhood only: keep edges to these unit types.'),
              via: names.merge(description: 'neighbourhood only: keep edges of these mechanisms.'),
              event: { type: 'string', enum: Woods::Diagrams::Lifecycle::EVENTS,
                       description: 'lifecycle only: create (default), update or destroy.' }
            },
            required: %w[kind identifier] }
        end

        # @param reader [IndexReader]
        # @param index_dir [String, Pathname] the index root
        # @param arguments [Hash] validated tool arguments
        # @return [Woods::Diagrams::Result]
        def call(reader, index_dir, kind:, identifier:, **options)
          Woods::Diagrams.build(reader, kind: kind, identifier: identifier, index_dir: index_dir,
                                        **options.compact.transform_keys(&:to_sym))
        end

        # @param result [Woods::Diagrams::Result]
        # @return [Hash] the structured data every answer carries
        def data(result)
          result.details.merge('generation' => result.generation)
        end

        # @param result [Woods::Diagrams::Result] a refused one
        # @return [String] the refusal and what to change
        def refusal_message(result)
          "#{result.refusal} (depth #{result.details['depth']}). No diagram is drawn above the budget; " \
            'retry with a smaller depth or narrower filters.'
        end
      end
    end
  end
end
