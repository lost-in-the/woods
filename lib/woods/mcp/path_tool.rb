# frozen_string_literal: true

require_relative '../dependency_graph'
require_relative '../edge_evidence'
require_relative 'identifier_suggestions'
require_relative 'tool_contract'
require_relative 'traversal_response'

module Woods
  module MCP
    # The `path` tool: how one unit reaches another, as the shortest chain of
    # published edges in the pinned generation. The search is
    # {Woods::DependencyGraph#shortest_path}; this module resolves the two
    # endpoints, refuses the ones it cannot, and words the answer. Always
    # registered: it needs nothing but the index, and nothing is precomputed.
    module PathTool
      NAME = 'path'

      DESCRIPTION = 'How does unit A reach unit B? Returns the shortest chain of published dependency edges from ' \
                    '`from` to `to`, one hop per line with every `via` label on that edge, and how Woods knows ' \
                    'each hop (evidence: reflected, verified, static or unknown; none means the code runs). ' \
                    'Use it for "how does X ' \
                    'reach Y", "is X connected to Y" and "what is between X and Y" instead of assembling the chain ' \
                    'from several dependencies/dependents calls. direction "forward" (default) follows edges from ' \
                    '`from`; "either" also tries `to` reaching `from` and says which direction the path runs. ' \
                    'No path is a successful answer that says whether the search was exhaustive or stopped by ' \
                    'max_depth or max_nodes: only an exhaustive one shows there is no path, and then only over ' \
                    'published relationships, which are not exhaustive source-reference coverage. Of several ' \
                    'shortest paths the same one is returned every time; paths never pass through documentation ' \
                    'units. An identifier registered under several types needs from_type or to_type.'

      # A request the tool cannot answer: an endpoint the graph does not hold,
      # or one it holds under several types with none named.
      class Refusal < StandardError
        # @return [Symbol] the `_meta.error_code`
        attr_reader :code
        # @return [Hash] further `_meta` fields
        attr_reader :meta

        # @param message [String]
        # @param code [Symbol]
        # @param meta [Hash]
        def initialize(message, code:, **meta)
          super(message)
          @code = code
          @meta = meta
        end
      end

      class << self
        # @return [Hash] the tool's input schema
        def schema
          { properties: {
              from: { type: 'string', description: 'Exact identifier of the unit the path starts at.' },
              to: { type: 'string', description: 'Exact identifier of the unit the path should reach.' },
              from_type: { type: 'string',
                           description: 'Unit type of `from`, when its identifier is registered under several.' },
              to_type: { type: 'string',
                         description: 'Unit type of `to`, when its identifier is registered under several.' },
              max_depth: { type: 'integer',
                           description: 'Most hops a path may have (default: ' \
                                        "#{ShortestPath::DEFAULT_MAX_DEPTH}; maximum: #{maximum('max_depth')})." },
              max_nodes: { type: 'integer',
                           description: 'Most units one search may reach (default and maximum: ' \
                                        "#{ShortestPath::DEFAULT_MAX_NODES})." },
              direction: { type: 'string', enum: ShortestPath::DIRECTIONS,
                           description: 'forward (default): follow edges from `from` toward `to`. either: when ' \
                                        'that finds nothing, also search from `to` toward `from`.' }
            },
            required: %w[from to] }
        end

        # @param reader [IndexReader] read inside one pinned generation
        # @param from [String]
        # @param to [String]
        # @param from_type [String, nil]
        # @param to_type [String, nil]
        # @param max_depth [Integer, nil]
        # @param max_nodes [Integer, nil]
        # @param direction [String, nil]
        # @return [Hash] {Woods::ShortestPath#call}'s answer, with `graph_coverage:` and, for no path, `hint:`
        # @raise [Refusal] for an endpoint that is unknown or names several units
        def call(reader, from:, to:, from_type: nil, to_type: nil, max_depth: nil, max_nodes: nil, direction: nil)
          graph = reader.dependency_graph
          # One identifier with one type named means that unit at both ends.
          if from == to
            from_type ||= to_type
            to_type ||= from_type
          end
          start = resolve(reader, graph, 'from', from, from_type)
          goal = resolve(reader, graph, 'to', to, to_type)
          result = graph.shortest_path(from, to, from_type: start, to_type: goal, direction: direction || 'forward',
                                                 max_depth: max_depth || ShortestPath::DEFAULT_MAX_DEPTH,
                                                 max_nodes: max_nodes || ShortestPath::DEFAULT_MAX_NODES)
          result[:graph_coverage] = TraversalResponse::COVERAGE
          hint = hint(result)
          result[:hint] = hint if hint
          result
        end

        # @param result [Hash] an answer of {.call}
        # @return [String] the sentence that states the answer
        def summary(result)
          return no_path_summary(result) unless result[:found]

          from = label(result[:from])
          to = label(result[:to])
          return "0 hops: `from` and `to` are the same unit, #{from}." if result[:hop_count].zero?

          hops = "#{result[:hop_count]} hop#{'s' unless result[:hop_count] == 1}"
          return "#{hops}, forward: #{from} reaches #{to}." if result[:direction] == 'forward'

          "#{hops}, reverse: #{to} reaches #{from}. #{forward_miss(result)}"
        end

        # @param hop [Hash] one hop of an answer
        # @return [String] e.g. `OrdersController (controller) -[code_reference]-> CheckoutService (service)`,
        #   followed by its evidence (`  [static]`) when that is weaker than `reflected`
        def hop_line(hop)
          others = Array(hop[:target_types]) - [hop[:target_type]]
          target = "#{hop[:target]} (#{hop[:target_type]}#{"; also #{others.join(', ')}" if others.any?})"
          via = hop[:via].empty? ? 'unlabelled' : hop[:via].join(', ')
          "#{hop[:source]} (#{hop[:source_type]}) -[#{via}]-> #{target}#{evidence_marker(hop)}"
        end

        # How well the path is supported, in one line ({Woods::EdgeEvidence}).
        #
        # @param result [Hash] an answer of {.call}
        # @return [String, nil] nil for an answer with no hops
        def evidence_line(result)
          evidence = result[:evidence]
          return nil unless evidence
          return 'Evidence: every hop is reflected (reported by Rails).' if evidence == EdgeEvidence::REFLECTED

          weakest = "Evidence: weakest hop is #{EdgeEvidence.label(evidence, result[:evidence_mixed])} " \
                    "(hop #{result[:weakest_hop]})"
          unknown = ': this build has no classification for that relationship' if evidence == EdgeEvidence::UNKNOWN
          "#{weakest}#{unknown}. #{EdgeEvidence::LEGEND}"
        end

        private

        # @return [String, nil]
        def evidence_marker(hop)
          evidence = hop[:evidence]
          return nil if evidence.nil? || evidence == EdgeEvidence::REFLECTED

          "  [#{EdgeEvidence.label(evidence, hop[:evidence_mixed])}]"
        end

        # @return [Integer] the wire contract's upper bound for an integer argument
        def maximum(argument)
          ToolContract::INTEGER_BOUNDS.fetch(argument).last
        end

        # @return [String] the unit type the endpoint resolves to
        # @raise [Refusal]
        def resolve(reader, graph, argument, identifier, type)
          types = graph.node_types(identifier).map(&:to_s)
          return type if type && types.include?(type)
          return types.first if type.nil? && types.size == 1

          raise ambiguous(argument, identifier, types) if type.nil? && types.size > 1

          raise missing(reader, argument, identifier, type, types)
        end

        # @return [Refusal]
        def ambiguous(argument, identifier, types)
          Refusal.new(
            "`#{argument}` is ambiguous: #{identifier} is registered under #{types.size} unit types " \
            "(#{types.join(', ')}). Pass #{argument}_type with one of them.",
            code: :ambiguous_identity, argument: "#{argument}_type", identifier: identifier, types: types
          )
        end

        # @return [Refusal]
        def missing(reader, argument, identifier, type, types)
          suggestions = reader.suggest_identifiers(identifier)
          message = "`#{argument}` unit not found: #{identifier}#{" (type #{type})" if type}"
          message += ". It is registered as: #{types.join(', ')}" if types.any?
          Refusal.new(
            IdentifierSuggestions.append("#{message}. Use `search` to find identifiers by pattern.", suggestions),
            code: :not_found, argument: argument, identifier: identifier, suggestions: suggestions
          )
        end

        # @return [String]
        def label(endpoint)
          "#{endpoint[:identifier]} (#{endpoint[:type]})"
        end

        # @return [String]
        def no_path_summary(result)
          from = label(result[:from])
          to = label(result[:to])
          either = result[:searches].size > 1
          route = either ? "between #{from} and #{to} in either direction" : "from #{from} to #{to}"
          search = result[:searches].first
          case result[:partial_reason]
          when nil
            "No path: no chain of published edges leads #{route}. The search was exhaustive."
          when 'max_depth'
            "No path within #{search[:max_depth]} hop#{'s' unless search[:max_depth] == 1} #{route}. The search " \
            'stopped at max_depth, so this does not show that no path exists.'
          else
            "No path found #{route} before the search reached its node budget (max_nodes " \
            "#{search[:max_nodes]}). This does not show that no path exists."
          end
        end

        # What to say about the forward search when only the reverse one found a path.
        #
        # @return [String]
        def forward_miss(result)
          forward = result[:searches].first
          from = result.dig(:from, :identifier)
          return "No published path leads forward from #{from}." if forward[:exhaustive]

          "The forward search from #{from} stopped at #{bound(forward)}, so a forward path may still exist."
        end

        # @return [String]
        def bound(search)
          search[:partial_reason] == 'max_depth' ? "max_depth #{search[:max_depth]}" : "max_nodes #{search[:max_nodes]}"
        end

        # @return [String, nil] what to try after an answer of no path
        def hint(result)
          return nil if result[:found]

          hints = []
          search = result[:searches].first
          if result[:partial_reason] == 'max_depth' && search[:max_depth] < maximum('max_depth')
            hints << "Retry with a larger max_depth (maximum #{maximum('max_depth')})."
          end
          if result[:partial_reason] == 'node_budget'
            hints << if search[:max_nodes] < maximum('max_nodes')
                       "Retry with a larger max_nodes (maximum #{maximum('max_nodes')})."
                     else
                       'Retry with a smaller max_depth so the search can finish within the node budget.'
                     end
          end
          if result[:searches].size == 1
            hints << "Pass direction: \"either\" to also search from #{result.dig(:to, :identifier)} " \
                     "toward #{result.dig(:from, :identifier)}."
          end
          hints.empty? ? nil : hints.join(' ')
        end
      end
    end
  end
end
