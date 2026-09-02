# frozen_string_literal: true

module Woods
  module Console
    # Shape-aware Layer 3 (column + EAV) redaction for console tool responses.
    #
    # Extracted from {Server} so the response-redaction logic can live next to
    # the {ResponseContext} that invokes it and be unit-tested without the
    # full server construction path.
    #
    # Redaction is shape-aware:
    #   - {record: Hash}                        (find)
    #   - {records: [Hash]}                     (sample, recent)
    #   - {columns: [...], rows: [[...]]}       (sql, query)
    #   - {columns: [...], values: [...|[...]]} (pluck)
    #   - Plain Hash                            (redact top-level keys)
    #   - Array<Hash>                           (redact each hash)
    module Redactor
      # Data-shape keys used by console tool responses. When any of these keys
      # appear at the top of a Hash result we treat the value as row data and
      # descend into it instead of redacting at the envelope level.
      #
      # Full recursive descent is intentionally NOT used here. Some tools return
      # Hashes whose keys happen to be column names but whose values are metadata
      # objects, not row data — e.g. `console_schema` returns
      # {columns: {col_name => {type:..., null:...}}}. Recursing into that Hash
      # would incorrectly replace schema metadata with "[REDACTED]" whenever a
      # column name matches a redacted_columns entry. Keeping a closed list of
      # envelope keys that carry actual row data is therefore the safer choice.
      #
      # When adding a new Tier 2/3 tool that returns row data under a new envelope
      # key, add that key here AND add a matching `when` branch in
      # `redact_envelope_value` that applies the appropriate redaction strategy.
      DATA_ENVELOPE_KEYS = %w[record records rows values associations].freeze

      module_function

      # Apply SafeContext column redaction to a result value.
      #
      # @param result [Object] The result from the bridge or embedded executor
      # @param ctx [SafeContext] The context with redacted_columns configured
      # @return [Object] Redacted result, same shape as input
      def apply(result, ctx)
        case result
        when Array
          result.map { |item| item.is_a?(Hash) ? apply(item, ctx) : item }
        when Hash
          redact_hash(result, ctx)
        else
          result
        end
      end

      def redact_hash(hash, ctx)
        string_keyed = hash.transform_keys(&:to_s)
        return ctx.redact(string_keyed) unless (string_keyed.keys & DATA_ENVELOPE_KEYS).any?

        plan = positional_plan(string_keyed['columns'], ctx)
        string_keyed.each_with_object({}) do |(key, value), out|
          out[key] = redact_envelope_value(key, value, plan, ctx)
        end
      end

      def redact_envelope_value(key, value, plan, ctx)
        case key
        when 'record'         then value.is_a?(Hash) ? ctx.redact(value) : value
        when 'records'        then redact_hash_array(value, ctx)
        when 'rows', 'values' then redact_positional(value, plan)
        when 'associations'   then redact_association_map(value, ctx)
        else                       value
        end
      end

      def redact_hash_array(value, ctx)
        Array(value).map { |row| row.is_a?(Hash) ? ctx.redact(row) : row }
      end

      # Redact an associations map returned by console_data_snapshot.
      #
      # The associations payload has the shape:
      #   { "assoc_name" => [Hash, ...], ... }
      # Each value is an Array of record Hashes. We redact each record
      # the same way we handle `records` (column-name + EAV rules).
      def redact_association_map(value, ctx)
        return value unless value.is_a?(Hash)

        value.each_with_object({}) do |(assoc_name, assoc_records), out|
          out[assoc_name] = redact_hash_array(assoc_records, ctx)
        end
      end

      # Precompute everything needed to redact positional rows for a given
      # `columns` header: the column-name mask plus any EAV key-value rules
      # resolved to column indexes.
      def positional_plan(columns, ctx)
        { mask: positional_mask(columns, ctx),
          kv_rules: positional_kv_rules(columns, ctx) }
      end

      # Precompute the positional redaction mask from a `columns` header.
      # Returns nil when there is nothing to redact so callers can short-circuit.
      def positional_mask(columns, ctx)
        return nil unless columns.is_a?(Array)

        redacted = ctx.redacted_columns
        return nil if redacted.empty?

        mask = columns.map { |name| redacted.include?(name.to_s) }
        mask.any? ? mask : nil
      end

      # Resolve EAV patterns against a `columns` header into concrete index
      # pairs. A rule only fires when both key_column and value_column are
      # present in the header, and costs nothing per row otherwise.
      #
      # A duplicated key or value header (an `AS` alias can shadow the real
      # column — CON-1) makes index attribution ambiguous: a last-index-wins
      # lookup would let the shadow steal the mask from the secret. The
      # executor refuses those selects up front; here, defense-in-depth
      # fails toward masking — every cell under a value-named header is
      # redacted unconditionally.
      def positional_kv_rules(columns, ctx)
        return [] unless columns.is_a?(Array)

        names = columns.map(&:to_s)
        ctx.redacted_key_values.filter_map { |pattern| positional_kv_rule(names, pattern) }
      end

      # One resolved rule for one EAV pattern, or nil when the header lacks
      # either column. Unambiguous headers get the key/value index pair;
      # duplicated headers get the unconditional mask list.
      def positional_kv_rule(names, pattern)
        key_idxs = names.each_index.select { |i| names[i] == pattern['key_column'] }
        val_idxs = names.each_index.select { |i| names[i] == pattern['value_column'] }
        return nil if key_idxs.empty? || val_idxs.empty?
        return { mask_idxs: val_idxs } unless key_idxs.one? && val_idxs.one?

        { key_idx: key_idxs.first, val_idx: val_idxs.first, sensitive: pattern['sensitive_keys'] }
      end

      # Redact positional row data using a precomputed plan. Handles both
      # nested arrays (multi-column pluck, sql/query rows) and flat scalar
      # arrays (pluck with a single column — Rails collapses the result).
      def redact_positional(rows, plan)
        return rows unless rows.is_a?(Array)
        return rows if plan[:mask].nil? && plan[:kv_rules].empty?

        rows.map do |row|
          row.is_a?(Array) ? redact_row(row, plan) : redact_scalar(row, plan[:mask])
        end
      end

      def redact_row(row, plan)
        result = apply_mask(row, plan[:mask])
        plan[:kv_rules].each do |rule|
          if rule[:mask_idxs]
            # Ambiguous (duplicated) headers: mask every value-named cell.
            rule[:mask_idxs].each { |idx| result[idx] = '[REDACTED]' }
          elsif rule[:sensitive].include?(row[rule[:key_idx]].to_s)
            result[rule[:val_idx]] = '[REDACTED]'
          end
        end
        result
      end

      def apply_mask(row, mask)
        return row.dup unless mask

        row.each_with_index.map { |value, idx| mask[idx] ? '[REDACTED]' : value }
      end

      def redact_scalar(value, mask)
        return value unless mask

        mask.first ? '[REDACTED]' : value
      end
    end
  end
end
