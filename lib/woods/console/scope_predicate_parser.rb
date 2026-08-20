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

      # Suffix classes, each with its own required value type. Ruby truthiness
      # treats any non-nil, non-false value as true — so without a strict type
      # check, `{status_present: "false"}` (a JSON string) inverts the caller's
      # intent instead of raising. `_eq`/`_not_eq`/`_matches` accept any scalar
      # and are intentionally not classified here.
      EXISTENCE_SUFFIXES = %w[_null _not_null _present _blank].freeze
      COMPARISON_SUFFIXES = %w[_gt _gteq _lt _lteq].freeze
      SET_SUFFIXES = %w[_in _not_in].freeze

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
            validate_suffix_value_type!(suffix, value)
            arel_nodes << build_node(relation, column, suffix, value)
          else
            @model_validator.validate_column!(@model_name, key)
            equality[raw_key] = value
          end
        end

        relation = relation.where(equality) if equality.any?
        arel_nodes.each { |node| relation = relation.where(node) }
        relation
      end

      private

      # Enforce the suffix-dependent value type before any Arel node is
      # built. `true`/`false` are checked by identity (`==`), not truthiness,
      # so a JSON string like `"false"` is rejected rather than silently
      # treated as truthy.
      #
      # @param suffix [String] One of SUPPORTED_SUFFIXES
      # @param value [Object] The predicate value
      # @raise [ValidationError] when the value's type doesn't match the suffix class
      def validate_suffix_value_type!(suffix, value)
        case suffix
        when *EXISTENCE_SUFFIXES
          return if [true, false].include?(value)

          raise ValidationError,
                "Predicate suffix '#{suffix}' requires a strict boolean value " \
                "(got #{value.class}: #{value.inspect}). #{SUFFIX_HINT}"
        when *COMPARISON_SUFFIXES
          return if value.is_a?(String) || value.is_a?(Numeric)

          raise ValidationError,
                "Predicate suffix '#{suffix}' requires a scalar (String or Numeric) value " \
                "(got #{value.class}: #{value.inspect}). #{SUFFIX_HINT}"
        end
        # _in/_not_in are intentionally not type-checked here: build_node
        # already wraps a scalar in a single-element Array via `Array(value)`,
        # a pre-existing, separately-tested convenience for callers building
        # scope hashes programmatically. The public JSON Schema still
        # requires a real array for _in/_not_in at the MCP boundary.
      end

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
