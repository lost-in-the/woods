# frozen_string_literal: true

require_relative 'model_validator'

module Woods
  module Console
    # Parses Ransack-style predicate suffixes in scope hashes and builds
    # safe Arel predicates without string interpolation.
    #
    # Supported suffixes:
    #   _eq, _not_eq           — equality / inequality
    #   _gt, _gteq, _lt, _lteq — numeric/date comparisons
    #   _in, _not_in           — set membership (value must be Array)
    #   _null, _not_null       — IS NULL / IS NOT NULL (value must be boolean)
    #   _present               — IS NOT NULL AND != '' (value must be boolean)
    #   _blank                 — IS NULL OR = '' (value must be boolean)
    #   _matches               — LIKE pattern
    #
    # Plain hash keys (no recognised suffix) are treated as equality conditions
    # and handled by the standard ActiveRecord where(hash) path.
    #
    # Every column reference is validated through ModelValidator#validate_column!
    # before an Arel node is built — SQL injection via column names is impossible.
    #
    # @example
    #   parser = ScopePredicateParser.new(model_name: 'Order', model_validator: validator)
    #   relation = parser.parse(Order, { status: 'paid', total_refund_gt: 0 })
    #
    class ScopePredicateParser
      SUPPORTED_SUFFIXES = %w[
        _eq _not_eq
        _gt _gteq _lt _lteq
        _in _not_in
        _null _not_null
        _present _blank
        _matches
      ].freeze

      # Suffix pattern — longest suffix match wins because we scan the full list.
      SUFFIX_PATTERN = /(_eq|_not_eq|_gteq|_lteq|_gt|_lt|_not_in|_not_null|_in|_null|_present|_blank|_matches)\z/

      SUFFIX_HINT = "Supported suffixes: #{SUPPORTED_SUFFIXES.join(', ')}.".freeze

      # @param model_name [String] ActiveRecord model name (e.g. 'Order')
      # @param model_validator [ModelValidator] Validates column names
      def initialize(model_name:, model_validator:)
        @model_name = model_name
        @model_validator = model_validator
      end

      # Parse a scope hash and return an ActiveRecord::Relation.
      #
      # Keys without a recognised suffix are collected into a plain equality
      # hash and applied via relation.where(hash) — the fast path.
      # Keys with a recognised suffix are validated and built via Arel.
      #
      # @param relation [ActiveRecord::Relation, Class] Starting relation
      # @param scope_hash [Hash] Scope conditions, possibly with predicate suffixes
      # @return [ActiveRecord::Relation]
      # @raise [ValidationError] on unknown column or unsupported suffix
      def parse(relation, scope_hash)
        equality = {}
        arel_nodes = []

        scope_hash.each do |raw_key, value|
          key = raw_key.to_s
          match = SUFFIX_PATTERN.match(key)

          if match
            suffix = match[1]
            column = key.delete_suffix(suffix)
            @model_validator.validate_column!(@model_name, column)
            arel_nodes << build_node(relation, column, suffix, value)
          else
            equality[raw_key] = value
          end
        end

        relation = relation.where(equality) if equality.any?
        arel_nodes.each { |node| relation = relation.where(node) }
        relation
      end

      private

      # Build an Arel predicate node for a validated column + suffix.
      #
      # @param relation [ActiveRecord::Relation, Class] Used to get the arel_table
      # @param column [String] Validated column name
      # @param suffix [String] One of SUPPORTED_SUFFIXES
      # @param value [Object] The predicate value
      # @return [Arel::Nodes::Node]
      def build_node(relation, column, suffix, value) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/AbcSize, Metrics/PerceivedComplexity
        attr = arel_table(relation)[column]

        case suffix
        when '_eq'      then attr.eq(value)
        when '_not_eq'  then attr.not_eq(value)
        when '_gt'      then attr.gt(value)
        when '_gteq'    then attr.gteq(value)
        when '_lt'      then attr.lt(value)
        when '_lteq'    then attr.lteq(value)
        when '_in'      then attr.in(Array(value))
        when '_not_in'  then attr.not_in(Array(value))
        when '_null'
          value ? attr.eq(nil) : attr.not_eq(nil)
        when '_not_null'
          value ? attr.not_eq(nil) : attr.eq(nil)
        when '_present'
          # present = NOT NULL AND NOT blank string
          value ? attr.not_eq(nil).and(attr.not_eq('')) : attr.eq(nil).or(attr.eq(''))
        when '_blank'
          # blank = NULL OR empty string
          value ? attr.eq(nil).or(attr.eq('')) : attr.not_eq(nil).and(attr.not_eq(''))
        when '_matches'
          attr.matches(value)
        else
          raise ValidationError, "Unsupported predicate suffix '#{suffix}'. #{SUFFIX_HINT}"
        end
      end

      # Extract the Arel table from a relation or model class.
      #
      # @param relation [ActiveRecord::Relation, Class]
      # @return [Arel::Table]
      def arel_table(relation)
        relation.respond_to?(:arel_table) ? relation.arel_table : relation.klass.arel_table
      end
    end
  end
end
