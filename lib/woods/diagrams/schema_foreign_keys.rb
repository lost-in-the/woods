# frozen_string_literal: true

module Woods
  module Diagrams
    # The relationships a table unit draws in the Schema diagram: its
    # published foreign keys, outgoing, and incoming from the table units the
    # generation's reverse edges name. The table holding the key is the many
    # side. A generation without reverse edges draws outgoing keys only.
    class SchemaForeignKeys
      # @param source [Source]
      def initialize(source)
        @source = source
      end

      # @param table [Hash] a published database_table unit
      # @param visited [Set] [identifier, type] pairs already followed; extended here
      # @return [Array<Array(Array, Hash, nil)>] [[line, [near, far]], the table unit the hop reaches] per key
      def hops(table, visited)
        outgoing = keys_of(table).map { |key| [line(key), target(key['to_table'], table, visited)] }
        incoming = incoming(table).map { |source, key| [line(key), follow(source, visited)] }
        outgoing + incoming
      end

      private

      def keys_of(table)
        Array(table.dig('metadata', 'foreign_keys')).grep(Hash)
      end

      def line(key)
        near = key['from_table'].to_s
        far = key['to_table'].to_s
        ["  #{entity(near)} }o--|| #{entity(far)} : \"#{key['column']}\"", [near, far]]
      end

      # A double quote cannot be escaped inside an entity name, so it reads as a single one.
      def entity(name)
        "\"#{name.tr('"', "'")}\""
      end

      # [source table unit, key] for each published key pointing at the table, by source then column.
      def incoming(table)
        name = table.dig('metadata', 'table_name')
        sources(table).flat_map do |source|
          keys_of(source).select { |key| key['to_table'] == name }.sort_by { |key| key['column'].to_s }
                         .map { |key| [source, key] }
        end
      end

      def sources(table)
        edges = Array(@source.graph.dig('reverse_via', table['identifier']))
        ids = edges.select { |edge| edge['via'].to_s == 'foreign_key' }.map { |edge| edge['source'].to_s }
        (ids.uniq - [table['identifier']]).sort.filter_map { |id| @source.unit(id, type: 'database_table') }
      end

      # A foreign key stays inside its database, so the target is the table of
      # that name there.
      def target(to_table, table, visited)
        database = table.dig('metadata', 'database')
        unit = ["table:#{database}.#{to_table}", "table:#{to_table}"].filter_map do |id|
          @source.unit(id, type: 'database_table')
        end.first
        unit && follow(unit, visited)
      end

      def follow(unit, visited)
        visited.add?([unit['identifier'], 'database_table']) ? unit : nil
      end
    end
  end
end
