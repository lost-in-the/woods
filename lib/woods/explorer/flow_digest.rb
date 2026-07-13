# frozen_string_literal: true

require 'json'

module Woods
  module Explorer
    # Ingests the precomputed per-action flow documents (flows/*.json, written
    # by FlowPrecomputer when precompute_flows is enabled) into two tiers:
    #
    #   summaries — one compact record per flow (entry point, route, the
    #               app-relevant calls/jobs/mailers/responses, units touched).
    #               Small enough to always embed; powers search, screens,
    #               impact confirmation, and route badges.
    #   ops       — the compacted operation trees (gem-noise stripped),
    #               powering the Trace view's step-by-step rendering. May be
    #               split into a sidecar file by SiteBuilder when large.
    #
    # Also builds the inverted indexes the Impact views need:
    #   unit_index   — unit identifier => [flow indices touching it]
    #   method_index — "Target#method" => [flow indices calling it]
    #
    # All output uses string keys and deterministic ordering (flows sorted by
    # entry point) so re-exports stay byte-identical.
    class FlowDigest
      # Operations whose target/method resolve into installed gems are
      # framework plumbing (importmap engines, instrumentation initializers…),
      # not app behavior — Trace hides them, data.json keeps the full docs.
      GEM_NOISE = %r{vendor/bundle|/gems/|/ruby/[\d.]+/}

      # Model-mutation method names that make a :call op count as a write
      # when its target is a model — feeds callback-trigger impact lookups.
      WRITE_METHODS = %w[create create! update update! save save! destroy destroy!
                         update_attributes update_attributes!].freeze

      # @param index_dir [String] extraction output directory
      def initialize(index_dir)
        @flows_dir = File.join(index_dir.to_s, 'flows')
      end

      # @return [Boolean] whether the extraction carries precomputed flows
      def available?
        File.directory?(@flows_dir) && !flow_files.empty?
      end

      # @return [Hash] { 'summaries' => [...], 'ops' => [...],
      #   'unit_index' => {unit => [i]}, 'method_index' => {'T#m' => [i]} }
      #   or an empty digest when no flows exist
      def build
        return empty_digest unless available?

        summaries = []
        ops = []
        flow_files.each do |file|
          doc = read_flow(file)
          next unless doc

          summaries << summarize(doc)
          ops << compact_steps(doc)
        end
        digest = { 'summaries' => summaries, 'ops' => ops }.merge(invert(summaries))
        # Cap the stored call lists only AFTER the method index is built, so a
        # flow with many distinct calls still indexes completely.
        summaries.each { |sum| sum['calls'] = sum['calls'].first(40) }
        digest
      end

      private

      def empty_digest
        { 'summaries' => [], 'ops' => [], 'unit_index' => {}, 'method_index' => {} }
      end

      # flow_index.json values are absolute paths from the extraction machine;
      # resolve by basename against the local flows/ directory instead.
      def flow_files
        @flow_files ||= Dir.children(@flows_dir)
                           .select { |f| f.end_with?('.json') && f != 'flow_index.json' }
                           .sort
                           .map { |f| File.join(@flows_dir, f) }
      end

      def read_flow(file)
        doc = JSON.parse(File.read(file, encoding: 'UTF-8'))
        doc.is_a?(Hash) ? doc : nil
      rescue StandardError
        nil
      end

      # -- summary tier -------------------------------------------------------

      def summarize(doc)
        acc = { calls: [], jobs: [], mailers: [], responses: [], writes: [], conditions: 0 }
        units = []
        Array(doc['steps']).each do |step|
          units << step['unit'] if step['unit']
          walk_ops(Array(step['operations']), acc)
        end
        {
          'entry' => doc['entry_point'],
          'route' => doc['route'].is_a?(Hash) ? [doc['route']['verb'], doc['route']['path']].compact : [],
          'units' => units.uniq,
          'calls' => acc[:calls].uniq,
          'jobs' => acc[:jobs].uniq,
          'mailers' => acc[:mailers].uniq,
          'writes' => acc[:writes].uniq,
          'responses' => acc[:responses].uniq,
          'conditions' => acc[:conditions]
        }
      end

      def walk_ops(operations, acc)
        operations.each do |op|
          next unless op.is_a?(Hash)

          case op['type']
          when 'call', 'dynamic_dispatch' then record_call(op, acc)
          when 'async' then record_async(op, acc)
          when 'response'
            acc[:responses] << [op['render_method'], op['status_code']].compact.join(':')
          when 'conditional'
            acc[:conditions] += 1
            walk_ops(Array(op['then_ops']), acc)
            walk_ops(Array(op['else_ops']), acc)
          when 'transaction'
            walk_ops(Array(op['nested']), acc)
          end
        end
      end

      def record_call(operation, acc)
        return if noise?(operation)

        target = operation['target'].to_s
        return if target.empty?

        acc[:calls] << "#{target}##{operation['method']}"
        acc[:writes] << target if WRITE_METHODS.include?(operation['method'].to_s)
      end

      def record_async(operation, acc)
        target = operation['target'].to_s
        return if target.empty?

        (target.end_with?('Mailer') ? acc[:mailers] : acc[:jobs]) << target
      end

      def noise?(operation)
        GEM_NOISE.match?("#{operation['target']}#{operation['method']}#{operation['condition']}")
      end

      # -- ops tier (compacted trees for the Trace view) ----------------------

      def compact_steps(doc)
        Array(doc['steps']).map do |step|
          {
            'u' => step['unit'],
            't' => step['type'],
            'ops' => compact_ops(Array(step['operations']))
          }
        end
      end

      def compact_ops(operations)
        operations.filter_map do |op|
          next unless op.is_a?(Hash)
          next if noise?(op)

          compact_op(op)
        end
      end

      def compact_op(operation)
        out = { 't' => operation['type'] }
        out['tgt'] = operation['target'] if operation['target']
        out['m'] = operation['method'] if operation['method']
        out['line'] = operation['line'] if operation['line']
        out['cond'] = operation['condition'] if operation['condition']
        out['status'] = operation['status_code'] if operation['status_code']
        out['render'] = operation['render_method'] if operation['render_method']
        out['then'] = compact_ops(Array(operation['then_ops'])) if operation['then_ops']
        out['else'] = compact_ops(Array(operation['else_ops'])) if operation['else_ops']
        out['ops'] = compact_ops(Array(operation['nested'])) if operation['nested']
        out
      end

      # -- inverted indexes ----------------------------------------------------

      def invert(summaries)
        unit_index = Hash.new { |h, k| h[k] = [] }
        method_index = Hash.new { |h, k| h[k] = [] }
        summaries.each_with_index do |summary, idx|
          summary['units'].each { |u| unit_index[u.to_s.split('#').first] << idx }
          summary['calls'].each { |c| method_index[c] << idx }
        end
        {
          'unit_index' => unit_index.transform_values(&:uniq).sort.to_h,
          'method_index' => method_index.transform_values(&:uniq).sort.to_h
        }
      end
    end
  end
end
