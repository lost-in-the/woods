# frozen_string_literal: true

require_relative 'text'

module Woods
  module Impact
    module Renderers
      # Bounded PR-sized summary: one visible item and five collapsed items per
      # section. Further entries stay in JSON and are counted explicitly.
      class Markdown
        SECTIONS = { 'changed' => 'Changed units', 'affected' => 'Affected units', 'flows' => 'Flows',
                     'risks' => 'Risks', 'tests' => 'Tests', 'unknowns' => 'Unknowns' }.freeze

        # @param data [Hash] validated version 1 report
        def initialize(data)
          @data = data
        end

        # @return [String] at most 60 lines, with bounded single-line item labels
        def render
          lines = header
          SECTIONS.each { |key, title| lines.concat(section(key, title)) }
          "#{lines.join("\n")}\n"
        end

        private

        def header
          coverage = @data.fetch('coverage')
          state = coverage['complete'] ? 'Declared complete report' : 'Incomplete report'
          facts = coverage.except('complete').map { |key, value| "#{key}=#{value}" }.join('; ')
          ['## Change impact', '', "**#{state}** · #{@data['unknowns'].size} unknown records · schema 1",
           scope,
           "Coverage: #{Text.markdown(facts)}", '']
        end

        def scope
          depth = Text.markdown(@data.dig('parameters', 'depth') || 'unavailable')
          if @data.dig('parameters', 'mode') == 'focus'
            roots = @data.fetch('focus')
            names = roots.first(3).map { |item| Text.identity(item) }.join('; ')
            extra = roots.size > 3 ? " (#{roots.size - 3} more; see JSON)" : ''
            return "Focus: #{roots.size} typed roots at gen:#{Text.markdown(@data.dig('endpoint', 'generation'))}; " \
                   "depth: #{depth} — #{Text.markdown(names)}#{extra}"
          end

          range = @data.fetch('range')
          "Range: gen:#{Text.markdown(range.dig('from', 'generation'))} → " \
            "gen:#{Text.markdown(range.dig('to', 'generation'))}; depth: #{depth}"
        end

        def section(key, title)
          items = @data.fetch(key)
          lines = ["### #{title} (#{items.size})"]
          if items.empty?
            return lines + ["- No entries recorded (coverage: #{Text.markdown(@data['coverage'][key])}).",
                            '']
          end

          lines << "- #{entry(key, items.first)}"
          if items.size > 1
            details = items.drop(1).first(5).map { |item| entry(key, item) }.join(' · ')
            details += " · #{items.size - 6} omitted; see JSON." if items.size > 6
            lines.push('', "<details><summary>#{items.size - 1} more entries</summary>", '', details, '', '</details>')
          end
          lines + ['']
        end

        def entry(key, item)
          Text.markdown(send("format_#{key}", item))
        end

        def format_changed(item)
          "#{Text.identity(item)} — #{item['status']}; facets: #{Array(item['facets']).join(', ')}; " \
            "categories: #{Array(item['categories']).join(', ')}"
        end

        def format_affected(item)
          "#{Text.identity(item)} — #{Text.context(item)}; distance: #{item['distance']}; " \
            "weight: #{item['weight'] || 'unavailable'}; #{Array(item['paths']).size} witness paths"
        end

        def format_flows(item)
          route = item['route'] || {}
          "#{item['entry_point']} — #{route['verb']} #{route['path']}; #{Text.context(item)}"
        end

        def format_risks(item)
          unit = item['unit'] || item
          label = unit.is_a?(Hash) ? Text.identity(unit) : Text.short(unit)
          "#{Text.context(item)}; #{item['kind']} — #{label}; evidence: #{Text.short(item['evidence'])}"
        end

        def format_tests(item)
          item.is_a?(Hash) ? Text.identity(item) : Text.short(item)
        end

        def format_unknowns(item)
          Text.short(item)
        end
      end
    end
  end
end
