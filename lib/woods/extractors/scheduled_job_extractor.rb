# frozen_string_literal: true

require 'yaml'

module CodebaseIndex
  module Extractors
    # ScheduledJobExtractor handles scheduled/recurring job configuration extraction.
    #
    # Scans three schedule file formats to extract one unit per scheduled entry:
    # - `config/recurring.yml` — Solid Queue recurring tasks
    # - `config/sidekiq_cron.yml` — Sidekiq-Cron scheduled jobs
    # - `config/schedule.rb` — Whenever DSL
    #
    # Each scheduled entry becomes its own ExtractedUnit with type `:scheduled_job`.
    # Identifiers are prefixed with "scheduled:" to avoid collision with JobExtractor units.
    #
    # @example
    #   extractor = ScheduledJobExtractor.new
    #   units = extractor.extract_all
    #   cleanup = units.find { |u| u.identifier == "scheduled:periodic_cleanup" }
    #
    class ScheduledJobExtractor
      # Schedule files to scan, mapped to their format
      SCHEDULE_FILES = {
        'config/recurring.yml' => :solid_queue,
        'config/sidekiq_cron.yml' => :sidekiq_cron,
        'config/schedule.rb' => :whenever
      }.freeze

      # Common cron patterns mapped to human-readable descriptions
      CRON_HUMANIZE = {
        '* * * * *' => 'every minute',
        '0 * * * *' => 'every hour',
        '0 0 * * *' => 'daily at midnight',
        '0 0 * * 0' => 'weekly on Sunday',
        '0 0 * * 1' => 'weekly on Monday',
        '0 0 1 * *' => 'monthly on the 1st',
        '0 0 1 1 *' => 'yearly on January 1st'
      }.freeze

      # Environment keys to unwrap when nested in YAML
      ENVIRONMENT_KEYS = %w[production development test staging].freeze

      def initialize
        @schedule_files = SCHEDULE_FILES.each_with_object({}) do |(relative_path, format), hash|
          full_path = Rails.root.join(relative_path)
          hash[full_path.to_s] = format if File.exist?(full_path)
        end
      end

      # Extract all scheduled job entries from all discovered schedule files.
      #
      # @return [Array<ExtractedUnit>] List of scheduled job units
      def extract_all
        @schedule_files.flat_map do |file_path, format|
          extract_scheduled_job_file(file_path, format)
        end
      end

      # Extract scheduled job entries from a single schedule file.
      #
      # Unlike other file-based extractors that return a single ExtractedUnit,
      # this returns an Array because each schedule file contains multiple entries.
      #
      # @param file_path [String] Path to the schedule file
      # @param format [Symbol, nil] One of :solid_queue, :sidekiq_cron, :whenever (inferred from filename if nil)
      # @return [Array<ExtractedUnit>] List of scheduled job units
      def extract_scheduled_job_file(file_path, format = nil)
        format ||= infer_format(file_path)
        case format
        when :solid_queue, :sidekiq_cron
          extract_yaml_schedule(file_path, format)
        when :whenever
          extract_whenever_schedule(file_path)
        else
          []
        end
      rescue StandardError => e
        Rails.logger.error("Failed to extract scheduled jobs from #{file_path}: #{e.message}")
        []
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # YAML-based formats (Solid Queue, Sidekiq-Cron)
      # ──────────────────────────────────────────────────────────────────────

      # Parse a YAML schedule file and produce units.
      #
      # @param file_path [String] Path to the YAML file
      # @param format [Symbol] :solid_queue or :sidekiq_cron
      # @return [Array<ExtractedUnit>]
      def extract_yaml_schedule(file_path, format)
        source = File.read(file_path)
        data = YAML.safe_load(source, permitted_classes: [Symbol])

        return [] unless data.is_a?(Hash) && data.any?

        entries = unwrap_environment_nesting(data)
        return [] unless entries.is_a?(Hash)

        entries.filter_map do |task_name, config|
          next unless config.is_a?(Hash)

          build_yaml_unit(task_name, config, file_path, source, format)
        end
      end

      # Detect and unwrap environment-nested YAML.
      #
      # If the top-level keys are environment names (production, development, etc.),
      # unwrap to the first environment's entries.
      #
      # @param data [Hash] Parsed YAML data
      # @return [Hash] Unwrapped entries
      def unwrap_environment_nesting(data)
        if data.keys.all? { |k| ENVIRONMENT_KEYS.include?(k.to_s) }
          data.values.first || {}
        else
          data
        end
      end

      # Build an ExtractedUnit from a YAML schedule entry.
      #
      # @param task_name [String] The task/job name key
      # @param config [Hash] The entry configuration
      # @param file_path [String] Path to the schedule file
      # @param source [String] Raw file content
      # @param format [Symbol] :solid_queue or :sidekiq_cron
      # @return [ExtractedUnit]
      def build_yaml_unit(task_name, config, file_path, source, format)
        job_class = config['class']
        cron = extract_cron(config, format)

        unit = ExtractedUnit.new(
          type: :scheduled_job,
          identifier: "scheduled:#{task_name}",
          file_path: file_path
        )

        unit.namespace = job_class.include?('::') ? job_class.split('::')[0..-2].join('::') : nil if job_class
        unit.source_code = source
        unit.metadata = {
          schedule_format: format,
          job_class: job_class,
          cron_expression: cron,
          queue: config['queue'],
          args: config['args'],
          frequency_human_readable: humanize_frequency(cron, format)
        }
        unit.dependencies = build_dependencies(job_class)

        unit
      end

      # Extract the cron/schedule expression from config.
      #
      # @param config [Hash] Entry configuration
      # @param format [Symbol] :solid_queue or :sidekiq_cron
      # @return [String, nil]
      def extract_cron(config, format)
        case format
        when :solid_queue
          config['schedule']
        when :sidekiq_cron
          config['cron']
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Whenever DSL (config/schedule.rb)
      # ──────────────────────────────────────────────────────────────────────

      # Parse a Whenever schedule.rb file using regex.
      #
      # @param file_path [String] Path to the schedule.rb file
      # @return [Array<ExtractedUnit>]
      def extract_whenever_schedule(file_path)
        source = File.read(file_path)
        blocks = parse_whenever_blocks(source)

        blocks.each_with_index.map do |block, index|
          build_whenever_unit(block, index, file_path, source)
        end
      end

      # Parse `every ... do ... end` blocks from Whenever DSL.
      #
      # @param source [String] Ruby source code
      # @return [Array<Hash>] Parsed block data
      def parse_whenever_blocks(source)
        blocks = []
        # Match: every <frequency>[, options] do ... end
        source.scan(/every\s+(.+?)\s+do\s*\n(.*?)end/m) do |frequency_str, body|
          # Clean up the frequency — strip trailing options like ", at: '...'"
          frequency = frequency_str.strip.sub(/,\s*at:.*\z/, '').strip

          command_type, command_body = detect_whenever_command(body)
          job_class = extract_job_class_from_runner(command_body) if command_type == :runner

          blocks << {
            frequency: frequency,
            frequency_str: frequency_str.strip,
            command_type: command_type,
            command_body: command_body,
            job_class: job_class
          }
        end

        blocks
      end

      # Detect the command type inside a Whenever block body.
      #
      # @param body [String] Block body content
      # @return [Array<Symbol, String>] Command type and body
      def detect_whenever_command(body)
        case body
        when /runner\s+"([^"]+)"/
          [:runner, ::Regexp.last_match(1)]
        when /rake\s+"([^"]+)"/
          [:rake, ::Regexp.last_match(1)]
        when /command\s+"([^"]+)"/
          [:command, ::Regexp.last_match(1)]
        else
          [:unknown, body.strip]
        end
      end

      # Extract a job class name from a runner string.
      #
      # Looks for patterns like `MyJob.perform_later` or `MyJob.perform_now`.
      #
      # @param runner_str [String] The runner command string
      # @return [String, nil] The job class name or nil
      def extract_job_class_from_runner(runner_str)
        return nil unless runner_str

        match = runner_str.match(/([A-Z]\w*(?:::\w+)*)\.perform_(later|now)/)
        match ? match[1] : nil
      end

      # Build an ExtractedUnit from a Whenever block.
      #
      # @param block [Hash] Parsed block data
      # @param index [Integer] Block index for identifier uniqueness
      # @param file_path [String] Path to schedule.rb
      # @param source [String] Raw file content
      # @return [ExtractedUnit]
      def build_whenever_unit(block, index, file_path, source)
        identifier = if block[:job_class]
                       "scheduled:whenever_#{block[:job_class].underscore}_#{index}"
                     else
                       "scheduled:whenever_task_#{index}"
                     end

        unit = ExtractedUnit.new(
          type: :scheduled_job,
          identifier: identifier,
          file_path: file_path
        )

        unit.namespace = block[:job_class].split('::')[0..-2].join('::') if block[:job_class]&.include?('::')
        unit.source_code = source
        unit.metadata = {
          schedule_format: :whenever,
          job_class: block[:job_class],
          cron_expression: block[:frequency],
          command_type: block[:command_type],
          frequency_human_readable: block[:frequency]
        }
        unit.dependencies = build_dependencies(block[:job_class])

        unit
      end

      # ──────────────────────────────────────────────────────────────────────
      # Format Detection
      # ──────────────────────────────────────────────────────────────────────

      # Infer the schedule format from the file path.
      #
      # @param file_path [String] Path to the schedule file
      # @return [Symbol] One of :solid_queue, :sidekiq_cron, :whenever
      def infer_format(file_path)
        basename = File.basename(file_path)
        SCHEDULE_FILES.each do |relative, fmt|
          return fmt if basename == File.basename(relative)
        end
        :unknown
      end

      # ──────────────────────────────────────────────────────────────────────
      # Shared helpers
      # ──────────────────────────────────────────────────────────────────────

      # Build dependency array linking to a job class.
      #
      # @param job_class [String, nil] The job class name
      # @return [Array<Hash>]
      def build_dependencies(job_class)
        return [] unless job_class

        [{ type: :job, target: job_class, via: :scheduled }]
      end

      # Humanize a cron expression or Solid Queue frequency string.
      #
      # @param expression [String, nil] Cron expression or frequency
      # @param format [Symbol] Schedule format
      # @return [String, nil]
      def humanize_frequency(expression, format)
        return nil unless expression

        # Solid Queue schedules are already human-readable
        return expression if format == :solid_queue

        # Check exact matches
        return CRON_HUMANIZE[expression] if CRON_HUMANIZE.key?(expression)

        # Check */N minute pattern
        return "every #{::Regexp.last_match(1)} minutes" if expression =~ %r{\A\*/(\d+) \* \* \* \*\z}

        # Fallback: return raw expression
        expression
      end
    end
  end
end
