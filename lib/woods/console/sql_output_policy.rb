# frozen_string_literal: true

module Woods
  module Console
    # Preserve protected column identity before legacy Console reads execute.
    # This policy supplements the existing output redactor without changing
    # the legacy tool surface or its explicitly opted-in mutation controls.
    module SqlOutputPolicy # rubocop:disable Metrics/ModuleLength -- one policy keeps output identity and EAV provenance together
      SELECT_EXPRESSION = /\A\s*
        (?:(SUM|AVG|MIN|MAX|COUNT)\s*\(\s*(\*|\w+(?:\.\w+)?)\s*\)|(\w+(?:\.\w+)?))
        (?:\s+AS\s+(\w+))?\s*\z/ix
      private_constant :SELECT_EXPRESSION

      private

      def redaction_columns
        @redaction_context.respond_to?(:redacted_columns) ? @redaction_context.redacted_columns : []
      end

      def redaction_key_values
        @redaction_context.respond_to?(:redacted_key_values) ? @redaction_context.redacted_key_values : []
      end

      def refuse_redacted_column!(column)
        return unless redaction_columns.any? { |name| name.to_s.casecmp?(column.to_s) }

        raise ValidationError,
              "Rejected: column '#{column}' is redacted (console_redacted_columns) and cannot be used " \
              'as a scope, filter, aggregate, find, or order key.'
      end

      def refuse_protected_predicate_column!(column)
        base = base_column_name(column.to_s)
        return refuse_redacted_column!(base) if redaction_columns.any? { |name| name.to_s.casecmp?(base) }
        return unless redacted_eav_value_columns.any? { |name| name.to_s.casecmp?(base) }

        raise ValidationError,
              "Rejected: EAV value column '#{base}' is redacted (console_redacted_key_values) and cannot " \
              'be used as a scope, filter, or having predicate.'
      end

      def redacted_eav_value_columns
        redaction_key_values.filter_map { |pattern| pattern['value_column'] }
      end

      def refuse_orphan_eav_value_selection!(expressions)
        selected = directly_selected_columns(expressions)

        redaction_key_values.each do |pattern|
          values = selected.select { |column| base_column_name(column).casecmp?(pattern['value_column']) }
          next if values.empty?

          keys = selected.select { |column| base_column_name(column).casecmp?(pattern['key_column']) }
          next if paired_eav_sources?(keys, values)

          raise ValidationError,
                "Rejected: selecting EAV value column '#{pattern['value_column']}' without its paired " \
                "key column '#{pattern['key_column']}' bypasses redaction; select both columns so the " \
                'value can be masked. Both columns must have the same unambiguous source.'
        end
      end

      def paired_eav_sources?(keys, values)
        return false unless keys.one? && values.one?

        keys.first.split('.')[0...-1] == values.first.split('.')[0...-1]
      end

      def directly_selected_columns(expressions)
        expressions.filter_map do |expr|
          match = SELECT_EXPRESSION.match(expr)
          next unless match

          fn_arg, bare_col, alias_name = match.captures[1..]
          next if fn_arg || alias_name

          bare_col
        end
      end

      def refuse_redacted_select_shapes!(captures, model_name)
        fn, fn_arg, bare_col, alias_name = captures
        column = bare_col || fn_arg
        validate_column_reference!(column, model_name) unless column == '*'

        refuse_protected_alias_target!(alias_name) if alias_name
        refuse_redacted_select_alias!(bare_col, alias_name) if alias_name
        refuse_redacted_aggregate_expression!(fn_arg) if fn
      end

      def refuse_protected_alias_target!(alias_name)
        return unless protected_column_name?(alias_name)

        raise ValidationError,
              "Rejected: alias '#{alias_name}' names a protected output header; an alias must not " \
              'collide with a redacted or EAV column name.'
      end

      def protected_column_name?(name)
        casecmp_member?(redaction_columns, name) ||
          casecmp_member?(redacted_kv_columns, name)
      end

      def casecmp_member?(list, name)
        list.any? { |entry| entry.to_s.casecmp?(name.to_s) }
      end

      def refuse_redacted_select_alias!(column, alias_name)
        return unless column

        base = base_column_name(column)
        if casecmp_member?(redaction_columns, base)
          raise ValidationError,
                "Rejected: aliasing redacted column '#{base}' as '#{alias_name}' bypasses output " \
                'redaction. Select it unaliased; the value is masked.'
        end

        return unless casecmp_member?(redacted_kv_columns, base)

        raise ValidationError,
              "Rejected: aliasing redacted key/value column '#{base}' as '#{alias_name}' bypasses " \
              'EAV output redaction. Select it unaliased.'
      end

      def refuse_redacted_aggregate_expression!(column)
        return if column.nil? || column == '*'

        base = base_column_name(column)
        if casecmp_member?(redaction_columns, base)
          raise ValidationError,
                "Rejected: aggregating redacted column '#{base}' reads its value; it cannot be used " \
                'as an aggregate input.'
        end

        return unless casecmp_member?(redacted_kv_columns, base)

        raise ValidationError,
              "Rejected: aggregating redacted key/value column '#{base}' reads its value; it cannot " \
              'be used as an aggregate input.'
      end

      def redacted_kv_columns
        redaction_key_values
          .flat_map { |pattern| [pattern['key_column'], pattern['value_column']] }
      end

      def base_column_name(column)
        column.split('.').last
      end

      def validate_protected_sql_usage!(sql)
        # This exact wrapper only preserves the inner statement's output
        # headers. SqlValidator has already checked balanced delimiters.
        limited = /\ASELECT \* FROM \(\n(.*)\n\) AS _limited LIMIT \d+\z/m.match(sql)
        if limited
          SqlValidator.new(dialect: sql_dialect, mysql_modes: mysql_quote_modes).validate!(limited[1])
          return validate_protected_sql_usage!(limited[1])
        end

        sql_security_views(sql).each { |stripped| validate_protected_sql_view!(stripped) }
      end

      def validate_protected_sql_view!(stripped)
        refuse_composite_sql_projection!(stripped)
        refuse_ambiguous_eav_sql!(stripped)
        protected = (redaction_columns + redacted_kv_columns).uniq
        referenced = protected.select { |column| sql_identifier_referenced?(stripped, column) }
        return if referenced.empty?

        expressions, tail = protected_sql_projection(stripped)
        selected = expressions.filter_map { |expression| direct_sql_column_name(expression) }
        unsafe = unsafe_protected_sql_column(referenced, expressions, selected, tail)
        return unless unsafe

        raise ValidationError,
              "Rejected: console_sql uses protected column '#{unsafe}' in an alias, aggregate, predicate, or " \
              'unpaired EAV shape that cannot preserve redaction identity. Select protected columns directly ' \
              'and unaliased, or use a structured Console tool.'
      end

      def refuse_ambiguous_eav_sql!(stripped)
        return if redaction_key_values.empty?
        return if SqlTableScanner.relation_factors(stripped).size <= 1
        return unless stripped.include?('*') || redacted_eav_value_columns.any? do |column|
          sql_identifier_referenced?(stripped, column)
        end

        raise ValidationError,
              'Rejected: SQL EAV values require one unambiguous source; use a structured Console query.'
      end

      def refuse_composite_sql_projection!(stripped)
        return unless [nil, :postgres].include?(sql_dialect)
        return if redaction_columns.empty? && redacted_kv_columns.empty?

        expressions = sql_select_expressions(stripped)
        sources = SqlTableScanner.relation_factors(stripped).flat_map { |factor| sql_relation_names(factor) }
        return unless sources.any? { |source| composite_sql_reference?(expressions, source) }

        raise ValidationError,
              'Rejected: whole-row SQL projections cannot preserve protected field identity; select columns.'
      end

      def sql_select_expressions(stripped)
        stripped.scan(/\bSELECT\s+(.*?)\s+FROM\b/im).flatten.flat_map { |list| sql_projection_expressions(list) }
      end

      def composite_sql_reference?(expressions, source)
        identifier = /(?:"#{Regexp.escape(source.gsub('"', '""'))}"|#{Regexp.escape(source)})/i
        token = /(?<![\w.$])#{identifier}(?![\w$]|\s*\.)/
        wildcard = /(?<![\w.$])#{identifier}\s*\.\s*\*/
        expressions.any? do |expression|
          expression.match?(token) || (expression.match?(wildcard) && !expression.match?(/\A#{wildcard}\z/))
        end
      end

      def sql_relation_names(factor)
        identifier = /(?:[[:alpha:]_][[:alnum:]_$]*|"(?:""|[^"])+")/
        source = /\A\s*(?:ONLY\b\s*\(?\s*)?(#{identifier})(?:\s*\.\s*(#{identifier}))?/i
        match = source.match(factor)
        names = match ? [match[2] || match[1]] : []
        rest = match ? factor[match.end(0)..].sub(/\A\s*\*/, '') : factor
        aliases = /(?:\A|\))\s*(?:AS\s+)?(#{identifier})/i
        names.concat(rest.scan(aliases).flatten)

        names.map { |name| name.delete_prefix('"').delete_suffix('"').gsub('""', '"') }
      end

      def unsafe_protected_sql_column(referenced, expressions, selected, tail)
        referenced.find do |column|
          unsafe_protected_sql_reference?(column, expressions, selected, tail)
        end || orphan_eav_sql_value(selected)
      end

      def protected_sql_projection(stripped)
        match = /\ASELECT\s+(.*?)\s+FROM\b/im.match(stripped)
        return [[], stripped] unless match

        [sql_projection_expressions(match[1]), stripped[match.end(1)..]]
      end

      def unsafe_protected_sql_reference?(column, expressions, selected, tail)
        unsafe_projection = expressions.any? do |expression|
          sql_identifier_referenced?(expression, column) && direct_sql_column_name(expression) != column
        end
        unsafe_tail = protected_sql_predicate_column?(column) && sql_identifier_referenced?(tail, column)
        !selected.include?(column) || unsafe_projection || unsafe_tail
      end

      def protected_sql_predicate_column?(column)
        redaction_columns.include?(column) || redacted_eav_value_columns.include?(column)
      end

      def orphan_eav_sql_value(selected)
        pattern = redaction_key_values.find do |candidate|
          selected.include?(candidate['value_column']) && !selected.include?(candidate['key_column'])
        end
        pattern&.fetch('value_column')
      end

      def sql_projection_expressions(projection)
        projection.split(',').map(&:strip)
      end

      def direct_sql_column_name(expression)
        identifier = /(?:[A-Za-z_]\w*|"(?:""|[^"])+"|`(?:``|[^`])+`)/
        match = /\A(?:#{identifier}\.)?(#{identifier})\z/.match(expression)
        return unless match

        match[1].sub(/\A["`]/, '').sub(/["`]\z/, '').gsub('""', '"').gsub('``', '`')
      end

      def sql_identifier_referenced?(sql, column)
        sql_security_views(sql).any? do |stripped|
          stripped.match?(/(?<![A-Za-z0-9_$])#{Regexp.escape(column)}(?![A-Za-z0-9_$])/i)
        end
      end

      def sql_security_views(sql)
        dialects = sql_dialect ? [sql_dialect] : SqlValidator::KNOWN_DIALECTS
        dialects.flat_map do |dialect|
          SqlNoiseStripper.security_views(sql, dialect: dialect, mysql_modes: sql_dialect ? mysql_quote_modes : nil)
        end.uniq
      end

      def validate_sql_result_types!(result)
        return unless sql_dialect == :postgres
        return if redaction_columns.empty? && redacted_kv_columns.empty?

        return if recognized_sql_result_types?(result)

        raise ValidationError,
              'Rejected: PostgreSQL returned an unrecognized result type that cannot preserve ' \
              'protected field identity. ' \
              'Select ordinary scalar columns or use a structured Console tool.'
      end

      def recognized_sql_result_types?(result)
        types = result.column_types if result.respond_to?(:column_types)
        return false unless types

        result.columns.each_with_index.all? do |column, index|
          type = types[index] || types[column]
          type&.type
        end
      end

      def mysql_quote_modes
        return {} unless sql_dialect == :mysql

        connection = active_connection
        cache = Thread.current[:woods_console_mysql_quote_modes]
        return cache[connection] if cache&.key?(connection)

        modes = connection.select_value('SELECT @@SESSION.sql_mode').to_s.upcase.split(',')
        result = {
          ansi_quotes: modes.include?('ANSI_QUOTES'),
          no_backslash_escapes: modes.include?('NO_BACKSLASH_ESCAPES')
        }
        cache[connection] = result if cache
        result
      end
    end
  end
end
