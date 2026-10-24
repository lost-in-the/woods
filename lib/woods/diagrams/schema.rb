# frozen_string_literal: true

require 'set'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require_relative 'builder'

module Woods
  module Diagrams
    # A model's table and its associations as an `erDiagram`, from published
    # model metadata. Depth 1 is the table and one hop of associations (the
    # Schema tab of Woods Map); each further depth adds the associations of
    # the models the previous hop reached. `through` associations are left
    # out (their join is drawn by its own associations). An association's far
    # table is the target model's published table, else Rails' default for
    # the class name. Entities are quoted, so `audit.logs` and `audit_logs`
    # stay apart.
    class Schema < Builder
      KIND = 'schema'
      OPTIONS = [].freeze

      # ER table budget (R-4).
      TABLE_BUDGET = 40

      private

      def prepare
        @unit = unit_of(%w[model database_table])
        @lines = relationship_lines
      end

      def budget
        TABLE_BUDGET
      end

      # @return [Integer] distinct tables drawn, the unit's own included
      def size
        tables.size
      end

      def refusal_text
        "#{size} tables is over the ER budget of #{TABLE_BUDGET}" if size > TABLE_BUDGET
      end

      def extra_details
        { 'table' => table_name(@unit), 'relationships' => @lines.size }
      end

      def mermaid
        lines = ['erDiagram']
        lines << "  #{entity(table_name(@unit))}" if table_name(@unit).present?
        (lines + @lines.map(&:first)).join("\n")
      end

      def tables
        # compact_blank arrived in Rails 6.1; the floor is 6.0.
        ([table_name(@unit)] + @lines.flat_map(&:last)).reject(&:blank?).uniq
      end

      # [line, [near table, far table]] for every hop, breadth-first. Depth 1
      # is the unit's associations exactly as declared; deeper lines already
      # drawn are not repeated.
      def relationship_lines
        result = []
        drawn = Set.new
        frontier = [@unit]
        visited = Set[[@unit['identifier'], @unit['type']]]
        (1..@depth).each do |level|
          frontier = frontier.flat_map do |model|
            associations(model).filter_map do |assoc|
              line = relationship(model, assoc)
              result << line if level == 1 || drawn.add?(line.first)
              drawn << line.first
              next_model(assoc, visited)
            end
          end
        end
        result
      end

      def relationship(model, assoc)
        near = table_name(model)
        far = target_table(assoc)
        cardinality = assoc['type'].to_s.start_with?('belongs_to') ? '}o--||' : '||--o{'
        ["  #{entity(near)} #{cardinality} #{entity(far)} : \"#{assoc['name']}\"", [near, far]]
      end

      def next_model(assoc, visited)
        identity = [assoc['target'].to_s.delete_prefix('::'), 'model']
        return nil unless visited.add?(identity)

        @source.unit(identity.first, type: 'model')
      end

      def associations(model)
        Array(model.dig('metadata', 'associations')).reject { |assoc| assoc['through'] }
      end

      def table_name(unit)
        metadata = unit['metadata'] || {}
        metadata['table_name'] || table_unit(unit)&.dig('metadata', 'table_name')
      end

      def table_unit(unit)
        unit['type'] == 'database_table' ? unit : nil
      end

      def target_table(assoc)
        target = assoc['target'].to_s
        @source.model_tables[target].presence || target.tableize.tr('/', '_')
      end

      # A double quote cannot be escaped inside an entity name, so it reads as a single one.
      def entity(name)
        "\"#{name.to_s.tr('"', "'")}\""
      end
    end
  end
end
