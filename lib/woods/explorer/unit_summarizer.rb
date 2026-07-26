# frozen_string_literal: true

module Woods
  module Explorer
    # Distills a unit's metadata into the compact, display-ready facts hash the
    # explorer frontend embeds per node. Richer than Woods::Export::UnitFacts
    # (which drops association names and callback side-effects) but still
    # bounded: every list is capped so a pathological unit can't balloon the
    # payload. All keys are strings — the hash is serialized to JSON verbatim.
    class UnitSummarizer
      # Upper bound applied to every list in the facts hash. When a list is
      # truncated the facts carry "<key>_total" with the real count.
      LIST_CAP = 60

      # @param unit [Hash] parsed unit JSON (string keys)
      def initialize(unit)
        @unit = unit || {}
        @meta = @unit['metadata'].is_a?(Hash) ? @unit['metadata'] : {}
      end

      # @return [Hash] type-specific facts (string keys, JSON-ready)
      def facts
        base = common_facts
        specific = case @unit['type']
                   when 'model' then model_facts
                   when 'controller' then controller_facts
                   when 'route' then route_facts
                   when 'job', 'scheduled_job' then job_facts
                   when 'mailer' then mailer_facts
                   when 'service', 'manager' then service_facts
                   when 'concern' then concern_facts
                   when 'view_template', 'component', 'view_component' then view_facts
                   else generic_facts
                   end
        apply_caps(base.merge(specific).compact)
      end

      # One-line human summary shown in search results and node tooltips.
      #
      # @return [String]
      def summary_line
        parts = summary_parts
        parts.empty? ? @unit['type'].to_s : parts.join(' · ')
      end

      private

      def common_facts
        git = @meta['git'].is_a?(Hash) ? @meta['git'] : {}
        {
          'loc' => @meta['loc'],
          'change_frequency' => git['change_frequency'],
          'last_author' => git['last_author'],
          'last_modified' => git['last_modified']
        }
      end

      def model_facts
        {
          'table_name' => @meta['table_name'],
          'columns' => columns,
          'columns_total' => columns.size,
          'associations' => associations,
          'validations' => validations,
          'callbacks' => callbacks,
          'scopes' => scope_names,
          'enums' => enums,
          'concerns' => list(@meta['inlined_concerns']),
          'sti' => sti_facts
        }
      end

      def controller_facts
        {
          'actions' => list(@meta['actions']),
          'routes' => controller_routes,
          'filters' => controller_filters,
          'permitted_params' => permitted_params,
          'concerns' => list(@meta['included_concerns'])
        }
      end

      def route_facts
        {
          'verb' => @meta['http_method'],
          'path' => @meta['path'],
          'controller' => @meta['controller'],
          'action' => @meta['action'],
          'route_name' => @meta['route_name']
        }
      end

      def job_facts
        {
          'queue' => @meta['queue'],
          'perform_params' => list(@meta['perform_params']).map { |p| param_name(p) },
          'retry_on' => list(@meta['retry_on']),
          'discard_on' => list(@meta['discard_on']),
          'enqueues' => list(@meta['enqueues_jobs'])
        }
      end

      def mailer_facts
        defaults = @meta['defaults'].is_a?(Hash) ? @meta['defaults'].compact : {}
        {
          'actions' => list(@meta['actions']),
          'defaults' => defaults,
          'templates' => @meta['templates'].is_a?(Hash) ? @meta['templates'] : {}
        }
      end

      def service_facts
        {
          'service_type' => @meta['service_type'],
          'entry_points' => list(@meta['entry_points']),
          'public_methods' => list(@meta['public_methods']),
          'callable' => @meta['is_callable']
        }
      end

      def concern_facts
        {
          'concern_type' => @meta['concern_type'],
          'concern_scope' => @meta['concern_scope'],
          'callbacks_defined' => list(@meta['callbacks_defined']),
          'scopes_defined' => list(@meta['scopes_defined']),
          'instance_methods' => list(@meta['instance_methods']),
          'class_methods' => list(@meta['class_methods'])
        }
      end

      def view_facts
        {
          'engine' => @meta['template_engine'],
          'partial' => @meta['is_partial'],
          'renders' => list(@meta['partials_rendered']),
          'helpers' => list(@meta['helpers_called']),
          'ivars' => list(@meta['instance_variables'])
        }
      end

      # Fallback for the long tail of unit types: keep scalar metadata and
      # shallow string lists, drop nested structures.
      def generic_facts
        @meta.each_with_object({}) do |(key, value), out|
          next if key == 'git'

          case value
          when String, Numeric, TrueClass, FalseClass then out[key] = value
          when Array then out[key] = value.grep(String)
          end
        end
      end

      # -- model helpers ------------------------------------------------------

      def columns
        @columns ||= list(@meta['columns']).filter_map do |col|
          next unless col.is_a?(Hash)

          { 'name' => col['name'], 'type' => col['type'], 'null' => col['null'] }.compact
        end
      end

      def associations
        list(@meta['associations']).filter_map do |assoc|
          next unless assoc.is_a?(Hash)

          opts = assoc['options'].is_a?(Hash) ? assoc['options'] : {}
          {
            'name' => assoc['name'], 'macro' => assoc['type'], 'target' => assoc['target'],
            'through' => assoc['through'], 'polymorphic' => assoc['polymorphic'],
            'dependent' => opts['dependent'], 'optional' => opts['optional']
          }.compact
        end
      end

      def validations
        list(@meta['validations']).filter_map do |val|
          next unless val.is_a?(Hash)

          attr = Array(val['attribute']).join(', ')
          "#{attr}: #{val['type']}"
        end
      end

      def callbacks
        list(@meta['callbacks']).filter_map do |cb|
          next unless cb.is_a?(Hash)

          {
            'type' => cb['type'], 'filter' => cb['filter'],
            'side_effects' => compact_side_effects(cb['side_effects'])
          }.compact
        end
      end

      def compact_side_effects(effects)
        return nil unless effects.is_a?(Hash)

        compacted = effects.select { |_k, v| v.is_a?(Array) && !v.empty? }
        compacted.empty? ? nil : compacted
      end

      def scope_names
        list(@meta['scopes']).filter_map { |s| s.is_a?(Hash) ? s['name'] : s }
      end

      def enums
        return {} unless @meta['enums'].is_a?(Hash)

        @meta['enums'].transform_values { |v| v.is_a?(Hash) ? v.keys : v }
      end

      def sti_facts
        return nil unless @meta['is_sti_base'] || @meta['is_sti_child']

        { 'base' => @meta['is_sti_base'], 'child' => @meta['is_sti_child'],
          'parent' => @meta['parent_class'] }.compact
      end

      # -- controller helpers -------------------------------------------------

      def controller_routes
        routes = @meta['routes']
        return {} unless routes.is_a?(Hash)

        routes.transform_values do |entries|
          list(entries).filter_map do |r|
            r.is_a?(Hash) ? [r['verb'], r['path']].compact.join(' ') : nil
          end
        end
      end

      def controller_filters
        list(@meta['filters']).filter_map do |f|
          next unless f.is_a?(Hash)

          desc = "#{f['kind']} #{f['filter']}"
          desc << " only=#{Array(f['only']).join(',')}" if f['only']
          desc << " except=#{Array(f['except']).join(',')}" if f['except']
          desc
        end
      end

      def permitted_params
        pp = @meta['permitted_params']
        return {} unless pp.is_a?(Hash)

        pp.transform_values { |v| v.is_a?(Hash) ? Array(v['permitted']) : Array(v) }
      end

      # -- shared helpers -----------------------------------------------------

      def param_name(param)
        param.is_a?(Hash) ? param['name'] : param
      end

      def list(value)
        value.is_a?(Array) ? value : []
      end

      # Truncates every oversize list in the facts hash and records the real
      # size as "<key>_total" so consumers (and AI agents reading data.json)
      # can tell a capped list from a complete one. columns_total is always
      # present (the detail panel leans on it); other totals appear only when
      # a list was actually truncated.
      def apply_caps(facts)
        facts.each_with_object({}) do |(key, value), out|
          out[key] = value
          next unless value.is_a?(Array) && value.size > LIST_CAP

          out[key] = value.first(LIST_CAP)
          out["#{key}_total"] = value.size unless out.key?("#{key}_total")
        end
      end

      def summary_parts
        case @unit['type']
        when 'model'
          [count_part(columns.size, 'column'), count_part(associations.size, 'association'),
           count_part(callbacks.size, 'callback'), count_part(scope_names.size, 'scope')].compact
        when 'controller'
          [count_part(list(@meta['actions']).size, 'action'),
           count_part(list(@meta['filters']).size, 'filter')].compact
        when 'route'
          [[@meta['http_method'], @meta['path']].compact.join(' ')].reject(&:empty?)
        when 'job', 'scheduled_job'
          ["queue: #{@meta['queue'] || 'default'}"]
        when 'mailer'
          [count_part(list(@meta['actions']).size, 'action')].compact
        when 'view_template'
          [@meta['is_partial'] ? 'partial' : 'template', @meta['template_engine']].compact
        else
          [count_part(@meta['loc'], 'line')].compact
        end
      end

      def count_part(count, noun)
        return nil unless count.is_a?(Integer) && count.positive?

        "#{count} #{noun}#{'s' unless count == 1}"
      end
    end
  end
end
