# frozen_string_literal: true

require 'strscan'

module Woods
  module Extractors
    # Describes standard cron lines in words for `frequency_human_readable`.
    #
    # Accepts the five-field form plus the extensions fugit reads for
    # sidekiq-cron and sidekiq-scheduler: `@daily`-style nicknames, a leading
    # seconds field, and a trailing time zone. A shape it cannot describe
    # exactly returns nil so the caller can echo the raw expression.
    #
    # @example
    #   CronHumanizer.humanize('0 7 * * *')   # => "daily at 07:00"
    #   CronHumanizer.humanize('0 8 * * 0')   # => "weekly on Sunday at 08:00"
    #   CronHumanizer.every('45m')            # => "every 45 minutes"
    module CronHumanizer
      # Shapes whose wording predates the general describer; kept verbatim.
      NAMED = {
        '* * * * *' => 'every minute',
        '0 * * * *' => 'every hour',
        '0 0 * * *' => 'daily at midnight'
      }.freeze

      NICKNAMES = {
        '@yearly' => '0 0 1 1 *', '@annually' => '0 0 1 1 *', '@monthly' => '0 0 1 * *',
        '@weekly' => '0 0 * * 0', '@daily' => '0 0 * * *', '@midnight' => '0 0 * * *',
        '@hourly' => '0 * * * *'
      }.freeze

      DAYS = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze
      MONTHS = %w[January February March April May June July August September October November
                  December].freeze

      # [minimum, maximum, names] per field: minute, hour, day, month, weekday.
      FIELDS = [
        [0, 59, {}],
        [0, 23, {}],
        [1, 31, {}],
        [1, 12, MONTHS.each_with_index.to_h { |name, index| [name[0, 3].downcase, index + 1] }],
        [0, 7, DAYS.each_with_index.to_h { |name, index| [name[0, 3].downcase, index] }]
      ].freeze

      TIME_ZONE = %r{\A(?:UTC|GMT|Z|[A-Za-z_]++(?:/[A-Za-z0-9_+-]++)++)\z}

      # Possessive and anchored by StringScanner, so a long digit run is read once.
      DURATION_COUNT = /\d++/
      DURATION_UNIT = /[yMwdhms]/
      PAIR_SEPARATOR = / ++/

      DURATION_UNITS = {
        'y' => 'year', 'M' => 'month', 'w' => 'week', 'd' => 'day', 'h' => 'hour', 'm' => 'minute', 's' => 'second'
      }.freeze

      module_function

      # @param expression [String, nil] a cron line
      # @return [String, nil] a description, or nil for a shape it does not describe
      def humanize(expression)
        fields = expression.to_s.split
        fields = NICKNAMES.fetch(fields.first.downcase).split + fields.drop(1) if NICKNAMES.key?(fields.first&.downcase)
        zone = fields.pop if fields.size > 5 && fields.last.match?(TIME_ZONE)
        text = describe_with_seconds(fields)
        text && zone ? "#{text} (#{zone})" : text
      end

      # Describe a sidekiq-scheduler `every`/`interval` duration.
      #
      # @param value [String, Array, nil] the duration, or `[duration, options]`
      # @return [String, nil]
      def every(value)
        duration = Array(value).first
        return nil if duration.nil?

        text = duration.to_s.strip
        parts = duration_parts(text)
        return "every #{text}" unless parts

        return "every #{DURATION_UNITS.fetch(parts.first.last)}" if parts.one? && parts.first.first == '1'

        "every #{parts.map { |count, unit| "#{count} #{DURATION_UNITS.fetch(unit)}#{'s' unless count == '1'}" }.join(' ')}"
      end

      # `1h 30m` => [["1", "h"], ["30", "m"]]; nil unless the whole text is count/unit
      # pairs, optionally separated by spaces.
      def duration_parts(text)
        scanner = StringScanner.new(text)
        parts = []
        until scanner.eos?
          scanner.skip(PAIR_SEPARATOR) unless parts.empty?
          count = scanner.scan(DURATION_COUNT)
          unit = count && scanner.scan(DURATION_UNIT)
          return nil unless unit

          parts << [count, unit]
        end
        parts.empty? ? nil : parts
      end

      def describe_with_seconds(fields)
        return describe(fields) if fields.size == 5
        return nil unless fields.size == 6

        seconds, *rest = fields
        return describe(rest) if seconds == '0'
        return nil unless rest.all?('*')
        return 'every second' if seconds == '*'

        step = seconds[%r{\A\*/(\d++)\z}, 1]&.to_i
        step&.between?(1, 59) ? quantity(step, 'second', every: true) : nil
      end

      def describe(fields)
        named = NAMED[fields.join(' ')]
        return named if named

        minute, hour, day, month, weekday = fields.each_with_index.map { |field, index| parse(field, FIELDS[index]) }
        return nil if [minute, hour, day, month, weekday].any?(&:nil?)

        months = month_phrase(day, month, weekday)
        return nil if months == :unsupported

        days = day_phrase(day, months ? :any : month, weekday)
        return nil if days == :unsupported

        clock = clock_times(minute, hour)
        text = if clock
                 clock_sentence(clock, days)
               else
                 recurring = recurring_phrase(minute, hour)
                 recurring && [recurring, recurring_suffix(days)].compact.join(' ')
               end
        text && [text, months].compact.join(' ')
      end

      # A field becomes :any, [:step, n], or [:set, [[from, to], ...]]; nil when unsupported.
      def parse(field, (min, max, names))
        return :any if field == '*'

        if (step = field[%r{\A\*/(\d++)\z}, 1])
          step = step.to_i
          return step.between?(1, max) ? [:step, step] : nil
        end

        items = field.split(',', -1).map { |item| parse_item(item, min, max, names) }
        items.all? ? [:set, items] : nil
      end

      def parse_item(item, min, max, names)
        bounds = item.split('-', -1)
        return nil unless bounds.size.between?(1, 2)

        from, to = bounds.map { |bound| value(bound, names) }
        to ||= from if bounds.one?
        return nil unless from && to && from.between?(min, max) && to.between?(from, max)

        [from, to]
      end

      def value(text, names)
        return text.to_i if text.match?(/\A\d++\z/)

        names[text.downcase]
      end

      def singles(field)
        return nil unless field.is_a?(Array) && field.first == :set

        values = field.last
        values.all? { |from, to| from == to } ? values.map(&:first) : nil
      end

      def clock_times(minute, hour)
        minutes = singles(minute)
        hours = singles(hour)
        return nil unless minutes && hours && minutes.size * hours.size <= 6

        hours.product(minutes).map { |h, m| clock(h, m) }
      end

      def recurring_phrase(minute, hour)
        minutes = singles(minute)
        case hour
        when :any
          return 'every minute' if [:any, [:step, 1]].include?(minute)
          return quantity(minute.last, 'minute', every: true) if minute.first == :step
          return 'every hour' if minutes == [0]

          minutes && "hourly at #{past_the_hour(minutes)}"
        else
          return minutes && stepped_hours(minutes, hour.last) if hour.first == :step

          hour_range(minute, hour.last)
        end
      end

      def stepped_hours(minutes, step)
        return "hourly at #{past_the_hour(minutes)}" if step == 1

        "every #{step} hours at #{past_the_hour(minutes)}"
      end

      # One hour range: the window runs from the first to the last firing.
      def hour_range(minute, ranges)
        return nil unless ranges.one? && ranges.first.first < ranges.first.last

        from, to = ranges.first
        minutes, phrase = minutes_within_hour(minute)
        minutes && "#{phrase} from #{clock(from, minutes.first)} to #{clock(to, minutes.last)}"
      end

      def minutes_within_hour(minute)
        return [(0..59).to_a, 'every minute'] if [:any, [:step, 1]].include?(minute)
        return [(0..59).step(minute.last).to_a, quantity(minute.last, 'minute', every: true)] if minute.first == :step

        minutes = singles(minute)
        minutes && [minutes, "hourly at #{past_the_hour(minutes)}"]
      end

      def past_the_hour(minutes)
        sentence(minutes.map { |minute| format(':%<minute>02d', minute: minute) })
      end

      def clock(hour, minute)
        format('%<hour>02d:%<minute>02d', hour: hour, minute: minute)
      end

      # A month restriction the yearly phrase does not absorb becomes a suffix.
      #
      # @return [nil, :unsupported, String]
      def month_phrase(day, month, weekday)
        return nil if month == :any
        return nil if weekday == :any && singles(day)&.one? && singles(month)&.one?
        return :unsupported unless month.first == :set

        names = month.last.map do |from, to|
          from == to ? MONTHS[from - 1] : "#{MONTHS[from - 1]} through #{MONTHS[to - 1]}"
        end
        "in #{sentence(names)}"
      end

      # @return [nil, :unsupported, Array] nil when every day matches
      def day_phrase(day, month, weekday)
        restricted = [day, month, weekday].map { |field| field != :any }
        case restricted
        when [false, false, false] then nil
        when [false, false, true] then weekday_phrase(weekday)
        when [true, false, false] then month_day_phrase(day)
        when [true, true, false] then yearly_phrase(day, month)
        else :unsupported
        end
      end

      def weekday_phrase(weekday)
        return :unsupported unless weekday.first == :set

        # 0 and 7 both mean Sunday.
        ranges = weekday.last
        expanded = ranges.flat_map { |from, to| (from..to).map { |day| day % 7 } }.uniq.sort
        return [:weekdays] if expanded == [1, 2, 3, 4, 5]
        return [:weekends] if expanded == [0, 6]

        names = ranges.map { |from, to| from == to ? DAYS[from % 7] : "#{DAYS[from % 7]} through #{DAYS[to % 7]}" }
        [:weekly, sentence(names)]
      end

      def month_day_phrase(day)
        return :unsupported unless day.first == :set

        ranges = day.last
        label = ranges.one? && ranges.first.first == ranges.first.last ? 'day' : 'days'
        [:monthly, "#{label} #{sentence(ranges.map { |from, to| from == to ? from.to_s : "#{from} through #{to}" })}"]
      end

      def yearly_phrase(day, month)
        days = singles(day)
        months = singles(month)
        return :unsupported unless days&.one? && months&.one?

        [:yearly, "#{MONTHS[months.first - 1]} #{days.first}"]
      end

      def clock_sentence(times, days)
        at = "at #{sentence(times)}"
        kind, words = days
        case kind
        when nil then "daily #{at}"
        when :weekdays then "weekdays #{at}"
        when :weekends then "weekends #{at}"
        else "#{kind} on #{words} #{at}"
        end
      end

      def recurring_suffix(days)
        kind, words = days
        case kind
        when nil then nil
        when :weekdays then 'on weekdays'
        when :weekends then 'on weekends'
        when :monthly then "on #{words} of the month"
        else "on #{words}"
        end
      end

      def quantity(count, unit, every: false)
        text = count == 1 ? unit : "#{count} #{unit}s"
        every ? "every #{text}" : text
      end

      def sentence(words)
        return words.first if words.one?

        "#{words[0..-2].join(', ')} and #{words.last}"
      end

      private_class_method :duration_parts, :describe_with_seconds, :describe, :parse, :parse_item, :value, :singles,
                           :clock_times, :recurring_phrase, :stepped_hours, :hour_range, :minutes_within_hour,
                           :past_the_hour, :clock, :month_phrase, :day_phrase,
                           :weekday_phrase, :month_day_phrase, :yearly_phrase, :clock_sentence,
                           :recurring_suffix, :quantity, :sentence
    end
  end
end
