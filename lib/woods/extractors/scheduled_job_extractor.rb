# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'
require_relative '../source_references/runtime_lookup'
require_relative 'periodic_registrations'
require_relative 'sidekiq_cron_registrations'
require_relative 'cron_humanizer'

require 'yaml'
require 'set'
begin
  require 'active_support/configuration_file'
rescue LoadError
  # Rails 6.0 predates ConfigurationFile.
  require 'erb'
end

module Woods
  module Extractors
    # ScheduledJobExtractor handles scheduled/recurring job configuration extraction.
    #
    # Scans three schedule file formats to extract one unit per scheduled entry:
    # - `config/recurring.yml` — Solid Queue recurring tasks
    # - `config/sidekiq_cron.yml` — Sidekiq-Cron scheduled jobs
    # - `config/schedule.rb` — Whenever DSL
    #
    # It also reads schedules registered from Ruby config sources
    # (`config/initializers/**/*.rb`, `config/environments/*.rb`,
    # `config/application.rb`): Sidekiq Enterprise `periodic` registrations
    # ({PeriodicRegistrations}) and Sidekiq-Cron jobs ({SidekiqCronRegistrations}).
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

      # Directories whose Ruby files may register schedules
      PERIODIC_SOURCE_DIRECTORIES = %w[config/initializers config/environments].freeze

      # Single files that may register schedules
      PERIODIC_SOURCE_FILES = %w[config/application.rb].freeze

      # Formats registered from Ruby sources, where one name may repeat.
      RUBY_FORMATS = %i[sidekiq_periodic sidekiq_cron_ruby].freeze

      # A Ruby source that mentions none of these registers no schedule; skip its parse.
      RUBY_SCHEDULE_HINT = /periodic|Cron::Job/

      # How a Ruby format names one of its entries in a warning.
      RUBY_FORMAT_LABELS = { sidekiq_cron_ruby: 'Sidekiq-Cron registration' }.freeze

      # Common cron patterns mapped to human-readable descriptions
      CRON_HUMANIZE = CronHumanizer::NAMED

      # A quoted Whenever command argument in either style. The body runs to
      # the *matching* delimiter, so the inner quotes of `command "echo 'hi'"`
      # stay part of the command.
      QUOTED_ARGUMENT = /(['"])((?:(?!\1).)+)\1/

      def initialize
        @schedule_files = SCHEDULE_FILES.each_with_object({}) do |(relative_path, format), hash|
          full_path = Rails.root.join(relative_path)
          hash[full_path.to_s] = format if File.exist?(full_path)
        end
        periodic_source_paths.each { |path| @schedule_files[path] = :ruby_config }
      end

      # Extract all scheduled job entries from all discovered schedule files.
      #
      # @return [Array<ExtractedUnit>] List of scheduled job units
      def extract_all
        allocate_identifiers(schedule_units(@schedule_files))
      end

      # Extract scheduled job entries from a single schedule file.
      #
      # Unlike other file-based extractors that return a single ExtractedUnit,
      # this returns an Array because each schedule file contains multiple entries.
      #
      # @param file_path [String] Path to the schedule file
      # @param format [Symbol] One of :solid_queue, :sidekiq_cron, :whenever, or :ruby_config
      #   (a Ruby config source; :sidekiq_periodic is accepted as an alias)
      # @return [Array<ExtractedUnit>] List of scheduled job units
      def extract_scheduled_job_file(file_path, format)
        path = File.expand_path(file_path.to_s)
        files = @schedule_files.merge(path => format)
        allocate_identifiers(schedule_units(files)).select { |unit| unit.file_path == path }
      end

      private

      def schedule_units(files)
        number_ruby_repeats(files.flat_map { |path, format| extract_schedule_file(path, format) })
      end

      def periodic_source_paths
        globbed = PERIODIC_SOURCE_DIRECTORIES.flat_map { |dir| Dir.glob(Rails.root.join(dir, '**', '*.rb').to_s) }
        files = PERIODIC_SOURCE_FILES.map { |file| Rails.root.join(file).to_s }.select { |path| File.file?(path) }
        (globbed + files).sort
      end

      def extract_schedule_file(file_path, format)
        case format
        when :solid_queue, :sidekiq_cron
          extract_yaml_schedule(file_path, format)
        when :whenever
          extract_whenever_schedule(file_path)
        when :ruby_config, :sidekiq_periodic
          extract_ruby_schedule(file_path)
        else
          []
        end
      rescue StandardError, SyntaxError, LoadError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract scheduled jobs from #{file_path}: #{e.message}")
        []
      end

      # Keep every unique legacy identifier. Reserve those first, then qualify
      # conflicting names in deterministic format order without stealing a
      # literal task name that already looks like one of our generated names.
      def allocate_identifiers(units)
        groups = units.group_by(&:identifier)
        reserved = groups.select { |_identifier, entries| entries.one? }.keys.to_set
        groups.keys.sort.each do |identifier|
          entries = groups.fetch(identifier)
          next if entries.one?

          formats = entries.map { |unit| unit.metadata.fetch(:schedule_format) }
          if formats.uniq.size != formats.size
            raise ArgumentError, "Ambiguous same-format schedule name: #{identifier.inspect}"
          end

          entries.sort_by { |unit| unit.metadata.fetch(:schedule_format).to_s }.each do |unit|
            base = "scheduled:#{unit.metadata.fetch(:schedule_format)}:#{identifier.delete_prefix('scheduled:')}"
            candidate = base
            suffix = 1
            while reserved.include?(candidate)
              suffix += 1
              candidate = "#{base}:#{suffix}"
            end
            unit.identifier = candidate
            reserved.add(candidate)
          end
        end
        units
      end

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
        data = if format == :solid_queue
                 # Match Solid Queue's trusted Rails configuration loader: ERB
                 # executes with its real filename (including require_relative).
                 load_recurring_configuration(file_path, source)
               else
                 # Sidekiq remains safe-loaded; aliases allow shared defaults
                 # without permitting additional deserialized classes (#203).
                 YAML.safe_load(source, permitted_classes: [Symbol], aliases: true)
               end

        return [] unless data.is_a?(Hash) && data.any?

        entries = unwrap_environment_nesting(data)
        return [] unless entries.is_a?(Hash)

        entries.filter_map do |task_name, config|
          next unless config.is_a?(Hash)

          build_yaml_unit(task_name, config, file_path, source, format)
        end
      end

      def load_recurring_configuration(file_path, source)
        if defined?(ActiveSupport::ConfigurationFile)
          ActiveSupport::ConfigurationFile.parse(file_path)
        else
          # Rails 6.0: preserve the same filename-aware ERB evaluation while
          # retaining the existing scalar/hash YAML policy.
          require 'erb'
          erb = ERB.new(source)
          erb.filename = file_path
          YAML.safe_load(erb.result, permitted_classes: [Symbol], aliases: true)
        end
      end

      # Detect and unwrap environment-nested YAML.
      #
      # If the top level contains maps of tasks, unwrap to the section for
      # the environment being extracted (including custom environment names),
      # falling back to the first section when the current environment has no
      # entry. Taking `values.first` unconditionally meant a file listing
      # `development:` before `production:` indexed the development schedule
      # and dropped production entirely (EXTB-19).
      #
      # @param data [Hash] Parsed YAML data
      # @return [Hash] Unwrapped entries
      def unwrap_environment_nesting(data)
        # Environment sections contain task maps; task entries contain scalar
        # configuration values. Shape matters even for a task called production.
        nested = data.values.all? do |section|
          section.nil? || (section.is_a?(Hash) && section.values.all?(Hash))
        end
        return data unless nested

        data.key?(current_environment) ? (data[current_environment] || {}) : (data.values.first || {})
      end

      # The environment name the extraction is running under, as a String.
      #
      # @return [String, nil]
      def current_environment
        Rails.env.to_s if defined?(Rails) && Rails.respond_to?(:env)
      rescue StandardError
        nil
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
          task_name: task_name.to_s,
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
      # The terminator is line-anchored (`^\s*end\s*$`), not the bare
      # substring `end` — that substring also occurs inside identifiers
      # (CalendarSyncJob, WeekendDigest), truncating the body so command
      # detection failed (#204). A nested `do ... end` inside an `every`
      # block still terminates the body at the nested block's own `end`
      # line; commands appearing before the nested block are detected,
      # anything after it is not.
      #
      # @param source [String] Ruby source code
      # @return [Array<Hash>] Parsed block data
      def parse_whenever_blocks(source)
        blocks = []
        # Match: every <frequency>[, options] do ... end (end on its own line)
        source.scan(/every\s+(.+?)\s+do\s*\n(.*?)^\s*end\s*$/m) do |frequency_str, body|
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
      # Both quote styles are accepted (EXTB-12): double-quote-only regexes
      # left `runner 'CleanupJob.perform_later'` — the frozen-string-literal
      # idiom — as command_type :unknown with no job class and no `:job` edge.
      #
      # @param body [String] Block body content
      # @return [Array<Symbol, String>] Command type and body
      def detect_whenever_command(body)
        case body
        when /runner\s+#{QUOTED_ARGUMENT}/o
          [:runner, ::Regexp.last_match(2)]
        when /rake\s+#{QUOTED_ARGUMENT}/o
          [:rake, ::Regexp.last_match(2)]
        when /command\s+#{QUOTED_ARGUMENT}/o
          [:command, ::Regexp.last_match(2)]
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
          task_name: identifier.delete_prefix('scheduled:'),
          job_class: block[:job_class],
          cron_expression: block[:frequency],
          command_type: block[:command_type],
          frequency_human_readable: humanize_whenever_frequency(block[:frequency])
        }
        unit.dependencies = build_dependencies(block[:job_class])

        unit
      end

      # ──────────────────────────────────────────────────────────────────────
      # Schedules registered from Ruby config sources
      # ──────────────────────────────────────────────────────────────────────

      # @param file_path [String] Path to a Ruby config source
      # @return [Array<ExtractedUnit>]
      def extract_ruby_schedule(file_path)
        source = File.read(file_path)
        return [] unless source.match?(RUBY_SCHEDULE_HINT)

        program = ScheduleLiterals.parse(source)
        periodic = PeriodicRegistrations.collect(program).filter_map do |registration|
          build_periodic_unit(registration, file_path, source)
        end
        cron = SidekiqCronRegistrations.collect(program).filter_map do |entry|
          build_ruby_entry_unit(entry, :sidekiq_cron_ruby, file_path, source)
        end
        periodic + cron
      end

      # @param registration [Hash] one entry from {PeriodicRegistrations.read}
      # @param file_path [String] Path to the Ruby config source
      # @param source [String] Raw file content
      # @return [ExtractedUnit, nil] nil when the job class is not a literal name
      def build_periodic_unit(registration, file_path, source)
        job_class = registration[:job_class]
        location = "#{file_path}:#{registration[:line]}"
        unless job_class
          Rails.logger.warn("[Woods] Skipping periodic registration at #{location}: job class is not a literal name")
          return nil
        end

        resolved = job_class_loaded?(job_class)
        unless resolved
          Rails.logger.warn("[Woods] Periodic registration at #{location} names #{job_class}, which is not a loaded class")
        end
        if registration[:cron_source]
          Rails.logger.warn("[Woods] Periodic registration at #{location}: cron is not a literal " \
                            "(#{registration[:cron_source]})")
        end

        unit = ExtractedUnit.new(type: :scheduled_job, identifier: "scheduled:#{job_class.underscore}",
                                 file_path: file_path)
        unit.namespace = job_class.split('::')[0..-2].join('::') if job_class.include?('::')
        unit.source_code = source
        unit.metadata = {
          schedule_format: :sidekiq_periodic,
          task_name: job_class.underscore,
          job_class: job_class,
          job_class_resolved: resolved,
          cron_expression: registration[:cron],
          queue: registration[:options]['queue'],
          options: registration[:options],
          line: registration[:line],
          frequency_human_readable: humanize_frequency(registration[:cron], :sidekiq_periodic)
        }
        unit.metadata[:cron_source] = registration[:cron_source] if registration[:cron_source]
        unit.dependencies = build_dependencies(job_class)
        unit
      end

      # A named schedule entry read from Ruby (Sidekiq-Cron, sidekiq-scheduler).
      #
      # @param entry [Hash] one {ScheduleLiterals.entry} plus `:line` and `:registration`
      # @param format [Symbol] one of {RUBY_FORMATS}
      # @param file_path [String] Path to the Ruby config source
      # @param source [String] Raw file content
      # @return [ExtractedUnit, nil] nil when neither the name nor the class is literal
      def build_ruby_entry_unit(entry, format, file_path, source)
        job_class = entry[:job_class]
        task_name = entry[:name] || job_class&.underscore
        unless task_name
          return warn_ruby_entry(entry, format, file_path, 'has neither a literal name nor a literal class')
        end

        resolved = job_class && job_class_loaded?(job_class)
        problems = []
        problems << 'job class is not a literal name' if entry[:job_class_source]
        problems << "names #{job_class}, which is not a loaded class" if job_class && !resolved
        problems << "cron is not a literal (#{entry[:cron_source]})" if entry[:cron_source]
        problems.each { |problem| warn_ruby_entry(entry, format, file_path, problem) }

        unit = ExtractedUnit.new(type: :scheduled_job, identifier: "scheduled:#{task_name}", file_path: file_path)
        unit.namespace = job_class.split('::')[0..-2].join('::') if job_class&.include?('::')
        unit.source_code = source
        options = entry[:options]
        unit.metadata = {
          schedule_format: format,
          task_name: task_name,
          job_class: job_class,
          job_class_resolved: resolved || false,
          cron_expression: entry[:cron],
          queue: options['queue'],
          args: options['args'],
          options: options,
          line: entry[:line],
          registration: entry[:registration],
          frequency_human_readable: humanize_frequency(entry[:cron], format),
          **entry.slice(:name_source, :job_class_source, :cron_source)
        }
        unit.dependencies = build_dependencies(job_class)
        unit
      end

      def warn_ruby_entry(entry, format, file_path, problem)
        Rails.logger.warn("[Woods] #{RUBY_FORMAT_LABELS.fetch(format)} at #{file_path}:#{entry[:line]} #{problem}")
        nil
      end

      def job_class_loaded?(job_class)
        @runtime_lookup ||= SourceReferences::RuntimeLookup.new
        @runtime_lookup.call(job_class)[:status] == :resolved
      end

      # Ruby registrations may repeat a name (one job class under several
      # crons, or one name in several environment files). Number the repeats
      # by source position so the names hold whatever order files arrive in.
      def number_ruby_repeats(units)
        ruby = units.select { |unit| RUBY_FORMATS.include?(unit.metadata[:schedule_format]) }
        ruby.group_by { |unit| [unit.metadata[:schedule_format], unit.identifier] }.each_value do |entries|
          entries.sort_by { |unit| [unit.file_path, unit.metadata[:line]] }.drop(1).each.with_index(2) do |unit, n|
            unit.identifier = "#{unit.identifier}:#{n}"
          end
        end
        units
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

        CronHumanizer.humanize(expression) || expression
      end

      # Whenever frequencies are Ruby (`1.day`, `:hour`); only a quoted cron
      # line is described, the rest stay as written.
      #
      # @param frequency [String] the `every` argument as written
      # @return [String]
      def humanize_whenever_frequency(frequency)
        cron = frequency[/\A#{QUOTED_ARGUMENT}\z/o, 2]
        (cron && CronHumanizer.humanize(cron)) || frequency
      end
    end
  end
end
