# frozen_string_literal: true

module Woods
  module Impact
    # A bounded line diff of two retained `source_code` strings (#802), so a
    # consumer can mark changed lines without diffing payloads itself.
    #
    # Myers' O(ND) algorithm after the common prefix and suffix are set
    # aside. Line numbers are 1-based in each endpoint's annotated
    # `source_code`, the coordinates `source_line_map` and the Code view use.
    # Hunks follow git's `-U0` convention: an empty side is `[line before,
    # 0]`. Past {MAX_LINES} lines on a side or {MAX_EDITS} edits nothing is
    # claimed: `coverage` says `too_large` and the counts are nil.
    class LineDiff
      # Lines on one side past which no diff is computed.
      MAX_LINES = 20_000
      # Edit distance past which no diff is computed.
      MAX_EDITS = 1_000
      # Lines of context a unified hunk carries on each side.
      CONTEXT = 3

      # @param before [String, nil]
      # @param after [String, nil]
      def initialize(before, after)
        @a = before.to_s.lines.map(&:chomp)
        @b = after.to_s.lines.map(&:chomp)
      end

      # @return [Boolean] whether the diff fits its bounds
      def computed?
        !script.nil?
      end

      # Changed ranges only.
      #
      # @param max_hunks [Integer] hunks kept; past it `coverage` is `truncated`
      # @return [Hash] `hunks` ([{before: [start, length], after: [start, length]}]),
      #   `added_lines`, `removed_lines` and `coverage` (complete, truncated or too_large)
      def ranges(max_hunks:)
        return { 'hunks' => [], 'added_lines' => nil, 'removed_lines' => nil, 'coverage' => 'too_large' } unless script

        groups = changed_groups
        kept = groups.first(max_hunks).map { |group| range(group) }
        { 'hunks' => kept, 'added_lines' => script.count { |op, *| op == '+' },
          'removed_lines' => script.count { |op, *| op == '-' },
          'coverage' => kept.size < groups.size ? 'truncated' : 'complete' }
      end

      # Unified hunks with context and the lines' text.
      #
      # @param max_lines [Integer] diff lines kept across all hunks
      # @return [Hash] {#ranges}' counts and coverage, with `hunks` carrying
      #   `lines` ([{op: ' ' | '+' | '-', before:, after:, text:}])
      def unified(max_lines:, context: CONTEXT)
        counts = ranges(max_hunks: script ? script.size : 0)
        return counts unless script

        budget = max_lines
        hunks = []
        contextual_groups(context).each do |entries|
          break if budget <= 0

          lines = entries.first(budget)
          budget -= lines.size
          hunks << unified_hunk(lines)
        end
        truncated = hunks.sum { |hunk| hunk['lines'].size } < contextual_groups(context).sum(&:size)
        counts.merge('hunks' => hunks, 'coverage' => truncated ? 'truncated' : 'complete')
      end

      private

      # The edit script: [op, before_line, after_line, text], nil past the bounds.
      def script
        return @script if defined?(@script)

        @script = if @a.size > MAX_LINES || @b.size > MAX_LINES then nil
                  else build_script
                  end
      end

      def build_script
        prefix = 0
        prefix += 1 while prefix < @a.size && prefix < @b.size && @a[prefix] == @b[prefix]
        suffix = 0
        suffix += 1 while suffix < @a.size - prefix && suffix < @b.size - prefix &&
                          @a[-1 - suffix] == @b[-1 - suffix]
        middle = myers(@a[prefix...(@a.size - suffix)], @b[prefix...(@b.size - suffix)])
        return nil unless middle

        head = (0...prefix).map { |i| [' ', i + 1, i + 1, @a[i]] }
        body = middle.map { |op, i, j, text| [op, i && (i + prefix + 1), j && (j + prefix + 1), text] }
        tail = (0...suffix).map do |k|
          i = @a.size - suffix + k
          j = @b.size - suffix + k
          [' ', i + 1, j + 1, @a[i]]
        end
        head + body + tail
      end

      # Myers' shortest edit script; 0-based indices; nil past MAX_EDITS.
      def myers(old, new)
        n = old.size
        m = new.size
        max = n + m
        return [] if max.zero?

        v = { 1 => 0 }
        trace = []
        (0..[max, MAX_EDITS].min).each do |d|
          trace << v.dup
          (-d..d).step(2) do |k|
            x = k == -d || (k != d && v[k - 1].to_i < v[k + 1].to_i) ? v[k + 1].to_i : v[k - 1].to_i + 1
            y = x - k
            while x < n && y < m && old[x] == new[y]
              x += 1
              y += 1
            end
            v[k] = x
            return backtrack(trace, old, new, [n, m]) if x >= n && y >= m
          end
        end
        nil
      end

      def backtrack(trace, old, new, ends)
        x, y = ends
        ops = []
        (trace.size - 1).downto(0) do |d|
          v = trace[d]
          k = x - y
          prev_k = k == -d || (k != d && v[k - 1].to_i < v[k + 1].to_i) ? k + 1 : k - 1
          prev_x = v[prev_k].to_i
          prev_y = prev_x - prev_k
          while x > prev_x && y > prev_y
            x -= 1
            y -= 1
            ops.unshift([' ', x, y, old[x]])
          end
          break if d.zero?

          ops.unshift(x == prev_x ? ['+', nil, prev_y, new[prev_y]] : ['-', prev_x, nil, old[prev_x]])
          x = prev_x
          y = prev_y
        end
        ops
      end

      # Runs of consecutive changed entries.
      def changed_groups
        script.chunk_while { |left, right| left[0] != ' ' && right[0] != ' ' }.reject { |group| group.first[0] == ' ' }
      end

      # The entry indices of each changed run widened by +context+, merged where they touch.
      def contextual_groups(context)
        @contextual_groups ||= {}
        @contextual_groups[context] ||= begin
          spans = []
          script.each_with_index do |(op, *), index|
            next if op == ' '

            first = [index - context, 0].max
            last = [index + context, script.size - 1].min
            spans.last && first <= spans.last[1] + 1 ? spans.last[1] = last : spans << [first, last]
          end
          spans.map { |first, last| script[first..last] }
        end
      end

      def range(group)
        removed = group.select { |op, *| op == '-' }
        added = group.select { |op, *| op == '+' }
        { 'before' => side(removed.map { |entry| entry[1] }, group, 1),
          'after' => side(added.map { |entry| entry[2] }, group, 2) }
      end

      # [start, length]; an empty side starts at the line before the change.
      def side(numbers, group, column)
        return [numbers.first, numbers.size] if numbers.any?

        index = script.index(group.first)
        previous = script[0...index].reverse.find { |entry| entry[column] }
        [previous ? previous[column] : 0, 0]
      end

      def unified_hunk(entries)
        before = entries.filter_map { |entry| entry[1] }
        after = entries.filter_map { |entry| entry[2] }
        { 'before' => [before.first || 0, before.size], 'after' => [after.first || 0, after.size],
          'lines' => entries.map { |op, i, j, text| { 'op' => op, 'before' => i, 'after' => j, 'text' => text } } }
      end
    end
  end
end
