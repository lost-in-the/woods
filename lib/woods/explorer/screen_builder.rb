# frozen_string_literal: true

require 'yaml'

module Woods
  module Explorer
    # Derives the Screen model — the explorer's user-facing atomic unit — from
    # routes, controller actions, the render closure, and navigation edges.
    #
    # A screen is one controller action with its routes, its precomputed flow
    # (when available), where it navigates next (links/forms found in the
    # views and components it renders, plus server redirects), and a
    # plain-language label. Labels come from an optional woods_labels.yml
    # (screens:/domains: maps); unlabeled screens get a humanized fallback.
    #
    # Output is deterministic: screens sorted by id, links sorted.
    class ScreenBuilder
      # How far to follow render edges from a controller when collecting the
      # views/components whose navigation edges belong to its screens.
      RENDER_DEPTH = 4

      # Navigation edge kinds that mean "this unit points the user at a
      # controller" — the outbound edges of a screen.
      NAV_VIAS = %w[link_to form_action].freeze

      # @param nodes [Array<Hash>] DataBuilder node entries (string keys)
      # @param edges [Array<Array>] [src_idx, tgt_idx, via] triples
      # @param flow_digest [Hash] FlowDigest#build output
      # @param labels [Hash] parsed woods_labels.yml ({'screens'=>{}, 'domains'=>{}})
      def initialize(nodes:, edges:, flow_digest:, labels: {})
        @nodes = nodes
        @edges = edges
        @flows = flow_digest
        @labels = labels.is_a?(Hash) ? labels : {}
        @index_of = nodes.each_with_index.to_h { |n, i| [n['id'], i] }
      end

      # @param path [String, nil] labels file location
      # @return [Hash] parsed labels or {}
      def self.load_labels(path)
        return {} unless path && File.file?(path)

        data = YAML.safe_load(File.read(path, encoding: 'UTF-8'))
        data.is_a?(Hash) ? data : {}
      rescue StandardError
        {}
      end

      # @return [Array<Hash>] screen records (string keys, sorted by id)
      def build
        flows_by_entry = {}
        @flows['summaries'].each_with_index { |s, i| flows_by_entry[s['entry']] = i }

        screens = controller_actions.map do |(controller, action), routes|
          screen_record(controller, action, routes, flows_by_entry)
        end
        attach_inbound(screens)
        screens.sort_by { |s| s['id'] }
      end

      private

      # -- discovery -----------------------------------------------------------

      # controller#action pairs from route facts (authoritative: verb/path per
      # action) plus flow entries not covered by a route (bare actions).
      def controller_actions
        pairs = Hash.new { |h, k| h[k] = [] }
        @nodes.each do |node|
          next unless node['type'] == 'controller'

          routes = node.dig('facts', 'routes')
          next unless routes.is_a?(Hash)

          routes.each do |action, entries|
            pairs[[node['id'], action]].concat(Array(entries))
          end
        end
        @flows['summaries'].each do |summary|
          controller, action = summary['entry'].to_s.split('#', 2)
          next unless action && @index_of.key?(controller)

          pairs[[controller, action]] ||= []
        end
        pairs.sort_by { |(controller, action), _| [controller, action] }.to_h
      end

      # -- record assembly -----------------------------------------------------

      # Route entries arrive as display strings ("POST /checkout") from
      # UnitSummarizer#controller_routes.
      def screen_record(controller, action, routes, flows_by_entry)
        id = "#{controller}##{action}"
        primary = routes.first.to_s.split(' ', 2).last.to_s
        {
          'id' => id,
          'controller' => controller,
          'action' => action,
          'node' => @index_of[controller],
          'routes' => routes,
          'flow' => flows_by_entry[id],
          'domain' => domain_for(primary, controller),
          'label' => label_for(id, controller, action),
          'out' => outbound(controller),
          'in' => 0
        }
      end

      # Outbound navigation: link/form edges collected from the controller's
      # render closure (controller-precise, '~' prefix — consumers render as
      # "via this controller's views") plus server redirect_to edges.
      def outbound(controller)
        out = []
        render_closure(controller).each do |unit_idx|
          edges_from(unit_idx).each do |(_, tgt, via)|
            next unless NAV_VIAS.include?(via)

            out << "~#{@nodes[tgt]['id']}"
          end
        end
        edges_from(@index_of[controller]).each do |(_, tgt, via)|
          out << "redirect:#{@nodes[tgt]['id']}" if via == 'redirect_to'
        end
        out.uniq.sort
      end

      # Views/components reachable from the controller over render-ish edges.
      def render_closure(controller)
        start = @index_of[controller]
        return [] unless start

        seen = { start => true }
        frontier = [start]
        depth = 0
        while depth < RENDER_DEPTH && !frontier.empty?
          frontier = frontier.flat_map do |idx|
            edges_from(idx).filter_map do |(_, tgt, via)|
              next unless %w[render view_render].include?(via)
              next if seen[tgt]

              seen[tgt] = true
              tgt
            end
          end
          depth += 1
        end
        seen.keys - [start]
      end

      def edges_from(idx)
        return [] if idx.nil?

        @edges_by_src ||= @edges.group_by(&:first)
        @edges_by_src[idx] || []
      end

      def attach_inbound(screens)
        counts = Hash.new(0)
        screens.each do |screen|
          screen['out'].each do |target|
            counts[target.delete_prefix('~').delete_prefix('redirect:')] += 1
          end
        end
        # Not combinable with the loop above: every screen's outbound list
        # must be counted before any screen's inbound total is read.
        screens.each do |screen| # rubocop:disable Style/CombinableLoops
          screen['in'] = counts[screen['controller']] + counts[screen['id']]
        end
      end

      # -- naming --------------------------------------------------------------

      def label_for(id, controller, action)
        explicit = @labels.dig('screens', id)
        return explicit if explicit

        base = controller.sub(/Controller\z/, '').split('::').last.to_s
        "#{humanize(base)} — #{humanize(action)}"
      end

      def domain_for(primary_path, controller)
        segment = primary_path.to_s.split('/').reject(&:empty?).first.to_s
        segment = nil if segment.empty? || segment.start_with?(':')
        key = segment || controller.split('::').first.to_s
        @labels.dig('domains', segment ? "/#{segment}" : key) ||
          @labels.dig('domains', key) ||
          humanize(key)
      end

      def humanize(text)
        text.to_s.gsub(/([a-z\d])([A-Z])/, '\1 \2').tr('_-', '  ').strip.capitalize
      end
    end
  end
end
