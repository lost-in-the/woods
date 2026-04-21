# frozen_string_literal: true

require 'set'
require 'woods/console/sql_table_scanner'

# @see Woods
module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Console
    class TableGateError < Woods::Error; end

    # Layer 1 of the Console defense-in-depth stack: rejects requests touching
    # blocked tables. SQL parsing is delegated to {SqlTableScanner}; this class
    # handles permission enforcement only. Raises {TableGateError} on violations.
    class TableGate
      # @param blocked_tables [Array<String>] case-insensitive; bare names match every schema.
      # @param model_tables [Hash{String=>String}] model => table.
      # @param model_reflections [Hash{String=>Hash{String=>String}}] model => assoc => table.
      def initialize(blocked_tables:, model_tables:, model_reflections: {})
        @blocked_bare = Set.new
        @blocked_qualified = Set.new
        Array(blocked_tables).each do |entry|
          name = entry.to_s.downcase
          next if name.empty?

          name.include?('.') ? @blocked_qualified << name : @blocked_bare << name
        end
        @model_tables = model_tables || {}
        @model_reflections = model_reflections || {}
      end

      def active? = !(@blocked_bare.empty? && @blocked_qualified.empty?)

      def check_sql!(sql)
        return unless active? && sql&.length&.positive?

        SqlTableScanner.identifiers_in(sql).each do |raw|
          raise TableGateError, reject_message(raw) if blocked?(raw)
        end
      end

      def check_model!(model_name)
        return unless active?

        table = @model_tables[model_name.to_s]
        check_table!(table) unless table.nil?
      end

      def check_table!(table_name)
        return unless active?
        return if table_name.nil? || table_name.to_s.empty?
        raise TableGateError, reject_message(table_name) if blocked?(table_name)
      end

      def check_joins!(model_name, joins) # rubocop:disable Metrics/CyclomaticComplexity
        return unless active? && joins && Array(joins).any?

        reflections = @model_reflections[model_name.to_s]
        return unless reflections

        Array(joins).each do |join|
          table = reflections[join.to_s]
          raise TableGateError, reject_message(table) if table && blocked?(table)
        end
      end

      def check_association!(model_name, association)
        return unless active? && association

        reflections = @model_reflections[model_name.to_s]
        return unless reflections

        table = reflections[association.to_s]
        raise TableGateError, reject_message(table) if table && blocked?(table)
      end

      private

      def blocked?(raw)
        name = raw.to_s.downcase
        @blocked_qualified.include?(name) || @blocked_bare.include?(strip_schema(name))
      end

      def strip_schema(raw) = raw.to_s.split('.').last.to_s

      def reject_message(name)
        "Rejected: table '#{name}' is on console_blocked_tables. " \
          'This tool is gated in Console MCP configuration.'
      end
    end
  end
end
