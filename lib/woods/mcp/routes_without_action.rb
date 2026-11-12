# frozen_string_literal: true

module Woods
  module MCP
    # The routed actions of a controller that nothing answers: no action
    # method, no gem-defined body, no implicit template, no `action_missing`.
    #
    # `resources :things` draws seven routes; a controller defining three
    # actions publishes all seven under `metadata.routes` and three under
    # `metadata.actions`, and nothing on the unit said the other four are dead.
    #
    # The verdict is {GraphAnalyzer#unresolvable_routes}' `missing_action`,
    # read from the generation's `graph_analysis.json`, so a controller and the
    # graph analysis never disagree. It is added when a unit is read and never
    # stored on it: whether a template serves an action is a fact of the graph
    # (`view_render` edges of view template units), and a controller is not
    # re-extracted when a template beside it is added or removed. A stored
    # verdict would go stale, as it would on a route unit.
    module RoutesWithoutAction
      # Metadata key added to a controller unit; present only when non-empty.
      KEY = 'routes_without_action'
      # Suffix of a flagged action's name in rendered `routes`.
      MARKER = ' (no action)'

      module_function

      # @param controller [String] controller identifier
      # @param graph_analysis [Hash, nil] parsed `graph_analysis.json`
      # @return [Array<String>] action names, sorted, each once; empty when
      #   every route resolves or the analysis carries no report
      def actions(controller, graph_analysis)
        entries = graph_analysis.is_a?(Hash) ? graph_analysis['unresolvable_routes'] : nil
        return [] unless entries.is_a?(Array)

        entries.filter_map do |entry|
          next unless entry.is_a?(Hash) && entry['controller'] == controller && entry['reason'] == 'missing_action'

          entry['action']
        end.uniq.sort
      end

      # A controller unit with {KEY} placed after `routes` (last when the unit
      # records no routes). Any other unit, and a controller whose every route
      # has an action, is returned as given.
      #
      # @param unit [Hash] published unit, string keys
      # @param graph_analysis [Hash, nil] parsed `graph_analysis.json`
      # @return [Hash] the unit, or a copy carrying the key
      def annotate(unit, graph_analysis)
        metadata = unit['metadata']
        return unit unless unit['type'] == 'controller' && metadata.is_a?(Hash)

        flagged = actions(unit['identifier'], graph_analysis)
        return unit if flagged.empty?

        unit.merge('metadata' => insert(metadata, flagged))
      end

      # {#annotate} with the analysis of the generation +reader+ serves. A
      # generation without a readable analysis leaves the unit as it is.
      #
      # @param unit [Hash] published unit, string keys
      # @param reader [#graph_analysis]
      # @return [Hash]
      def annotate_from(unit, reader)
        return unit unless unit['type'] == 'controller'

        annotate(unit, reader.graph_analysis)
      rescue StandardError
        unit
      end

      # The name a renderer prints for one entry of a metadata Hash: a flagged
      # action under `routes` carries {MARKER}; everything else is unchanged.
      #
      # @param metadata [Hash] the unit's metadata
      # @param key [String] the metadata key being rendered
      # @param name [String] the entry's own key
      # @return [String]
      def route_label(metadata, key, name)
        return name.to_s unless key.to_s == 'routes' && Array(metadata[KEY]).include?(name.to_s)

        "#{name}#{MARKER}"
      end

      # @return [Hash] metadata with the key after `routes`, or last
      def insert(metadata, flagged)
        rest = metadata.except(KEY)
        return rest.merge(KEY => flagged) unless rest.key?('routes')

        rest.each_with_object({}) do |(key, value), result|
          result[key] = value
          result[KEY] = flagged if key == 'routes'
        end
      end
      private_class_method :insert
    end
  end
end
