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

      # Keep legacy scope syntax while refusing protected values as inputs.
      # The same check runs before every model read, including association
      # scopes, so filtering cannot disclose a value hidden by the renderer.
      def refuse_protected_scope!(scope)
        case scope
        when Hash
          scope.each do |key, value|
            column = key.to_s.sub(ScopePredicateParser::SUFFIX_PATTERN, '')
            refuse_protected_predicate_column!(column)
            refuse_protected_scope!(value) if value.is_a?(Hash)
          end
        when Array
          refuse_protected_predicate_references!(scope.first) if scope.first.is_a?(String)
        end
      end

      def refuse_orphan_eav_value_selection!(expressions, model_name = nil)
        selected = directly_selected_columns(expressions)

        redaction_key_values.each do |pattern|
          values = selected.select { |column| base_column_name(column).casecmp?(pattern['value_column']) }
          values.select! { |column| eav_source_has_key?(column, pattern, model_name) }
          next if values.empty?

          keys = selected.select { |column| base_column_name(column).casecmp?(pattern['key_column']) }
          next if paired_eav_sources?(keys, values)

          raise ValidationError,
                "Rejected: selecting EAV value column '#{pattern['value_column']}' without its paired " \
                "key column '#{pattern['key_column']}' bypasses redaction; select both columns so the " \
                'value can be masked. Both columns must have the same unambiguous source.'
        end
      end

      def eav_source_has_key?(column, pattern, model_name)
        columns = if column.include?('.')
                    @model_validator.columns_for_table(column.split('.')[0...-1].join('.'))
                  elsif model_name
                    @model_validator.columns_for(model_name)
                  end
        columns.nil? || columns.include?(pattern['key_column'])
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
        refuse_sql_column_alias_lists!(stripped)
        refuse_composite_sql_projection!(stripped)
        refuse_ambiguous_eav_sql!(stripped)
        refuse_protected_sql_positions!(stripped)
        protected = (redaction_columns + redacted_kv_columns).uniq
        referenced = protected.select { |column| sql_identifier_referenced?(stripped, column) }
        return if referenced.empty?

        expressions, tail = protected_sql_projection(stripped)
        selected = expressions.filter_map { |expression| direct_sql_column_name(expression) }
        unsafe = unsafe_protected_sql_column(referenced, expressions, selected, tail, stripped)
        return unless unsafe

        raise ValidationError,
              "Rejected: console_sql uses protected column '#{unsafe}' in an alias, aggregate, predicate, or " \
              'unpaired EAV shape that cannot preserve redaction identity. Select protected columns directly ' \
              'and unaliased, or use a structured Console tool.'
      end

      # Relation/CTE column lists rename fields by position, before output
      # headers are available. Refuse them whenever either policy is active,
      # independently of protected-name references or function validation.
      def refuse_sql_column_alias_lists!(stripped)
        return if redaction_columns.empty? && redacted_kv_columns.empty?

        identifier = /(?:[A-Za-z_\u0080-\u{10ffff}][A-Za-z0-9_$\u0080-\u{10ffff}]*|"(?:""|[^"])+"|`(?:``|[^`])+`)/u
        list = /#{identifier}\s*\(\s*#{identifier}(?:\s*,\s*#{identifier})*\s*\)/
        cte = /#{list}\s*AS\s*(?:(?:NOT\s+)?MATERIALIZED\s*)?\(/i
        relation = /\A\s*(?:AS\s+)?#{list}/i
        renamed = stripped.match?(cte) || SqlTableScanner.relation_factors(stripped).any? do |factor|
          sql_relation_alias_tail(factor).match?(relation)
        end
        return unless renamed

        raise ValidationError,
              'Rejected: SQL relation or CTE column alias lists cannot preserve redaction identity. ' \
              'Select protected columns directly and unaliased, or use a structured Console tool.'
      end

      # Consume only the leading source, leaving its optional alias. Balanced
      # sources include subqueries, ONLY(table), and table-function arguments;
      # scalar functions elsewhere in the clause are not alias declarations.
      def sql_relation_alias_tail(factor)
        tokens = sql_policy_tokens(factor)
        index = %w[ONLY LATERAL].include?(sql_token_text(tokens, 0)) ? 1 : 0
        unless sql_token_text(tokens, index) == '('
          index += 1
          index += 2 while sql_token_text(tokens, index) == '.'
        end
        index = sql_after_parentheses(tokens, index) if sql_token_text(tokens, index) == '('
        index += 1 if sql_token_text(tokens, index) == '*'
        tokens[index] ? factor[tokens[index][:start]..] : ''
      end

      def sql_after_parentheses(tokens, index)
        depth = tokens[index][:depth]
        closing = ((index + 1)...tokens.length).find do |offset|
          tokens[offset][:text] == ')' && tokens[offset][:depth] == depth
        end
        closing ? closing + 1 : tokens.length
      end

      # Result metadata provides column names, not their table provenance.
      # A joined/derived EAV row can supply a key from a different source.
      # Keep direct single-source SQL reads and qualified structured joins;
      # refuse ambiguous SQL shapes before fetching their values.
      def refuse_ambiguous_eav_sql!(stripped)
        return if sql_eav_patterns(stripped).empty?
        return if SqlTableScanner.relation_factors(stripped).size <= 1
        return unless stripped.include?('*') || redacted_eav_value_columns.any? do |column|
          sql_identifier_referenced?(stripped, column)
        end

        raise ValidationError,
              'Rejected: SQL EAV values require one unambiguous source; use a structured Console query.'
      end

      # PostgreSQL can return a table alias as one composite-valued column.
      # Its header carries no identities for the protected fields inside it.
      # Reject source names used as projection values, including nested forms.
      def refuse_composite_sql_projection!(stripped)
        return if redaction_columns.empty? && redacted_kv_columns.empty?

        sources = SqlTableScanner.relation_factors(stripped).flat_map { |factor| sql_relation_names(factor) }
        tokens = sql_policy_tokens(stripped)
        return unless whole_row_value?(tokens, sources)

        raise ValidationError,
              'Rejected: whole-row SQL values cannot preserve protected field identity; select columns.'
      end

      # Track each query's clause separately, including correlated expressions
      # without a FROM clause. Relation declarations and qualified columns are
      # not values; a source token anywhere else may be a composite row.
      def whole_row_value?(tokens, sources)
        clauses = {}
        query_levels = {}
        tokens.each_with_index.any? do |token, index|
          clause = sql_clause_at_token(token, clauses, query_levels)
          next false unless clause && !%w[FROM JOIN STRAIGHT_JOIN].include?(clause)
          next false unless sources.any? { |source| sql_unquote(token[:text]).casecmp?(source) }

          !sql_nonvalue_reference?(tokens, index)
        end
      end

      def sql_clause_at_token(token, clauses, query_levels)
        word, depth = token.values_at(:text, :depth)
        keyword = word.upcase
        if word == '('
          clauses[depth + 1] = 'EXPRESSION'
          query_levels.delete(depth + 1)
        end
        if word == ')'
          clauses.delete(depth + 1)
          query_levels.delete(depth + 1)
        end
        query_levels[depth] = true if keyword == 'SELECT'
        boundaries = %w[SELECT FROM JOIN STRAIGHT_JOIN ON WHERE HAVING ORDER GROUP LIMIT OFFSET]
        clauses[depth] = keyword if query_levels[depth] && boundaries.include?(keyword)
        clauses[depth]
      end

      def sql_nonvalue_reference?(tokens, index)
        previous = index.positive? ? tokens[index - 1][:text].upcase : nil
        return true if ['.', 'AS'].include?(previous)
        return true if sql_token_text(tokens, index + 1) == '.' && sql_token_text(tokens, index + 2) != '*'

        direct_sql_wildcard?(tokens, index)
      end

      def sql_token_text(tokens, index)
        tokens[index]&.fetch(:text)&.upcase
      end

      def direct_sql_wildcard?(tokens, index)
        return false unless sql_token_text(tokens, index + 1) == '.' && sql_token_text(tokens, index + 2) == '*'

        previous = index.positive? ? sql_token_text(tokens, index - 1) : nil
        following = sql_token_text(tokens, index + 3)
        %w[SELECT ,].include?(previous) && [nil, ',', 'FROM'].include?(following)
      end

      # Comments and literal bodies have already been removed. Token offsets
      # let projection and ordinal checks retain complete nested expressions.
      def sql_policy_tokens(stripped)
        depth = 0
        stripped.to_enum(:scan, /"(?:[^"]|"")*"|`(?:[^`]|``)*`|''|
                                   [A-Za-z_\u0080-\u{10ffff}][A-Za-z0-9_$\u0080-\u{10ffff}]*|[0-9]+|::|[^\s]/ux).map do
          match = Regexp.last_match
          word = match[0]
          depth -= 1 if word == ')'
          token = { text: word, depth: depth, start: match.begin(0), finish: match.end(0) }
          depth += 1 if word == '('
          token
        end
      end

      def sql_unquote(identifier)
        identifier.sub(/\A["`]/, '').sub(/["`]\z/, '').gsub('""', '"').gsub('``', '`')
      end

      def sql_select_lists(stripped)
        tokens = sql_policy_tokens(stripped)
        tokens.each_with_index.filter_map do |token, index|
          next unless token[:text].casecmp?('SELECT')

          finish = tokens[(index + 1)..].find { |candidate| sql_projection_end?(candidate, token) }
          finish_at = finish ? finish[:start] : stripped.length
          { expressions: sql_projection_expressions(stripped[token[:finish]...finish_at]),
            depth: token[:depth], start: token[:start], finish: finish_at }
        end
      end

      def sql_projection_end?(candidate, token)
        candidate[:depth] < token[:depth] ||
          (candidate[:depth] == token[:depth] &&
            %w[FROM WHERE GROUP HAVING ORDER LIMIT UNION INTERSECT EXCEPT].include?(candidate[:text].upcase))
      end

      def refuse_protected_sql_positions!(stripped)
        lists = sql_select_lists(stripped)
        sql_policy_tokens(stripped).each_cons(3) do |clause, by, position|
          next unless %w[ORDER GROUP].include?(clause[:text].upcase) && by[:text].casecmp?('BY')

          list = sql_projection_before(lists, clause)
          next unless list
          next unless sql_projection_expressions(stripped[position[:start]..]).any? do |item|
            protected_sql_ordinal?(item, list[:expressions])
          end

          raise ValidationError,
                'Rejected: positional SQL ordering or grouping cannot reference protected output columns.'
        end
      end

      def sql_projection_before(lists, clause)
        lists.reverse.find do |candidate|
          candidate[:depth] == clause[:depth] && candidate[:start] < clause[:start]
        end
      end

      def protected_sql_ordinal?(item, expressions)
        ordinal = /\A\s*\(*\s*([0-9]+)\s*\)*(?:\s|\z)/.match(item)
        return false unless ordinal && ordinal[1].to_i.positive?

        expression = expressions[ordinal[1].to_i - 1]
        return false unless expression
        return true if expression.include?('*')

        (redaction_columns + redacted_eav_value_columns).any? do |column|
          sql_identifier_referenced?(expression, column)
        end
      end

      def sql_relation_names(factor)
        identifier = /(?:[A-Za-z_\u0080-\u{10ffff}][A-Za-z0-9_$\u0080-\u{10ffff}]*|"(?:""|[^"])+"|`(?:``|[^`])+`)/u
        source = /\A\s*(?:ONLY\b\s*\(?\s*)?(#{identifier})(?:\s*\.\s*(#{identifier}))?/i
        match = source.match(factor)
        names = match ? [match[2] || match[1]] : []
        rest = match ? factor[match.end(0)..].sub(/\A\s*\*/, '') : factor
        aliases = /(?:\A|\))\s*(?:AS\s+)?(#{identifier})/i
        names.concat(rest.scan(aliases).flatten)

        names.map { |name| sql_unquote(name) }
      end

      def unsafe_protected_sql_column(referenced, expressions, selected, tail, stripped)
        referenced.find do |column|
          unsafe_protected_sql_reference?(column, expressions, selected, tail)
        end || orphan_eav_sql_value(selected, stripped)
      end

      def protected_sql_projection(stripped)
        list = sql_select_lists(stripped).first
        return [[], stripped] unless list && list[:start].zero?

        [list[:expressions], stripped[list[:finish]..]]
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

      def orphan_eav_sql_value(selected, stripped)
        pattern = sql_eav_patterns(stripped).find do |candidate|
          selected.include?(candidate['value_column']) && !selected.include?(candidate['key_column'])
        end
        pattern&.fetch('value_column')
      end

      def sql_eav_patterns(stripped)
        tables = SqlTableScanner.identifiers_in(stripped, dialect: sql_dialect, mysql_modes: mysql_quote_modes)
        redaction_key_values.select do |pattern|
          tables.any? do |table|
            columns = @model_validator.columns_for_table(table)
            columns.nil? || [pattern['key_column'], pattern['value_column']].all? { |column| columns.include?(column) }
          end
        end
      end

      def sql_projection_expressions(projection)
        commas = sql_policy_tokens(projection).select { |token| token[:text] == ',' && token[:depth].zero? }
        start = 0
        commas.map do |token|
          expression = projection[start...token[:start]].strip
          start = token[:finish]
          expression
        end + [projection[start..].strip]
      end

      def direct_sql_column_name(expression)
        identifier = /(?:[A-Za-z_]\w*|"(?:""|[^"])+"|`(?:``|[^`])+`)/
        match = /\A(?:#{identifier}\.)?(#{identifier})\z/.match(expression)
        return unless match

        match[1].sub(/\A["`]/, '').sub(/["`]\z/, '').gsub('""', '"').gsub('``', '`')
      end

      def refuse_protected_predicate_references!(template)
        protected = (redaction_columns + redacted_eav_value_columns).uniq
        referenced = protected.find { |column| sql_identifier_referenced?(template, column) }
        refuse_protected_predicate_column!(referenced) if referenced
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
