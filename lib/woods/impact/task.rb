# frozen_string_literal: true

require_relative 'report'
require_relative 'renderers'
require_relative 'store'

module Woods
  module Impact
    # Local report computation, saving and rendering without booting Rails.
    class Task
      FORMATS = %w[markdown json mermaid].freeze

      # @param from [String, Integer, nil] required range base selector
      # @param to [String, Integer, nil] range head selector, default now
      # @param env [Hash] FORMAT, FOCUS, AT, WOODS_OUTPUT and WOODS_IMPACT_OPTIONS
      # @param output [IO] report-only stream
      # @param error [IO] local saved-report location stream
      def initialize(from: nil, to: nil, env: ENV, output: $stdout, error: $stderr)
        @from = from
        @to = to
        @env = env
        @output = output
        @error = error
      end

      # @return [String] saved-report ID
      def run
        validate
        directory = output_dir
        report = compute(directory)
        json = report.to_json
        rendered = @format == 'json' ? json : Renderers.public_send(@format, report)
        store = Store.new(directory)
        id = store.save(json)
        @output.write(rendered)
        @error.puts("Saved impact report #{id}: #{store.path_for(id)}")
        id
      end

      private

      def validate
        @format = @env.fetch('FORMAT', 'markdown')
        raise ArgumentError, 'FORMAT must be markdown, json or mermaid' unless FORMATS.include?(@format)

        validate_mode
        @options = parse('WOODS_IMPACT_OPTIONS', '{}')
        raise ArgumentError, 'WOODS_IMPACT_OPTIONS must be a JSON object' unless @options.is_a?(Hash)

        @options = @options.transform_keys(&:to_sym)
        Options.new(**@options)
      end

      def validate_mode
        @focus = @env.key?('FOCUS')
        @focus ? validate_focus : validate_range
      end

      def validate_focus
        raise ArgumentError, 'FOCUS cannot be combined with a range' if @from || @to

        @identities = parse('FOCUS')
        raise ArgumentError, 'FOCUS needs 1..10000 exact typed identifier/type objects' unless valid_focus?

        @at = @env.fetch('AT', 'now')
      end

      def validate_range
        raise ArgumentError, 'AT requires FOCUS' if @env.key?('AT')
        raise ArgumentError, 'A from selector is required' if @from.nil? || @from.to_s.strip.empty?

        @to = 'now' if @to.nil?
      end

      def valid_focus?
        @identities.is_a?(Array) && @identities.size.between?(1, 10_000) && @identities.all? do |item|
          valid_identity?(item)
        end
      end

      def valid_identity?(item)
        item.is_a?(Hash) && item.keys.sort == %w[identifier type] &&
          item.values.all? { |value| value.is_a?(String) && !value.empty? }
      end

      def parse(name, fallback = nil)
        JSON.parse(@env.fetch(name, fallback))
      rescue JSON::ParserError, TypeError
        raise ArgumentError, "Invalid #{name} JSON"
      end

      def output_dir
        @env.fetch('WOODS_OUTPUT') do
          require_relative '../../woods'
          Woods.configuration.output_dir
        end
      end

      def compute(directory)
        if @focus
          Report.focus(directory, identities: @identities, at: @at, **@options)
        else
          Report.compare(directory, from: @from, to: @to, **@options)
        end
      end
    end
  end
end
