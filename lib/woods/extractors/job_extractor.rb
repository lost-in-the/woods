# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # JobExtractor handles ActiveJob and Sidekiq job extraction.
    #
    # Background jobs are critical for understanding async behavior.
    # They often perform important business logic that would otherwise
    # be unclear from just looking at models and controllers.
    #
    # We extract:
    # - Queue configuration
    # - Retry/error handling configuration
    # - Arguments (the job's interface)
    # - What the job calls (dependencies)
    # - What triggers this job (reverse lookup via dependencies)
    #
    # @example
    #   extractor = JobExtractor.new
    #   units = extractor.extract_all
    #   order_job = units.find { |u| u.identifier == "ProcessOrderJob" }
    #
    class JobExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Directories to scan for jobs
      JOB_DIRECTORIES = %w[
        app/jobs
        app/workers
        app/sidekiq
      ].freeze

      def initialize
        @directories = JOB_DIRECTORIES.map { |d| Rails.root.join(d) }
                                      .select(&:directory?)
      end

      # Extract all jobs in the application
      #
      # @return [Array<ExtractedUnit>] List of job units
      def extract_all
        units = []

        # File-based discovery (catches everything)
        @directories.each do |dir|
          Dir[dir.join('**/*.rb')].each do |file|
            unit = extract_job_file(file)
            units << unit if unit
          end
        end

        # Also try class-based discovery for ActiveJob
        if defined?(ApplicationJob)
          seen = units.to_set(&:identifier)
          ApplicationJob.descendants.each do |job_class|
            next if seen.include?(job_class.name)

            unit = extract_job_class(job_class)
            if unit
              units << unit
              seen << unit.identifier
            end
          end
        end

        units.compact
      end

      # Extract a job from its file
      #
      # @param file_path [String] Path to the job file
      # @return [ExtractedUnit, nil] The extracted unit
      def extract_job_file(file_path)
        source = File.read(file_path)
        class_name = extract_class_name(file_path, source)

        return nil unless class_name
        return nil unless job_file?(source)

        unit = ExtractedUnit.new(
          type: :job,
          identifier: class_name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(class_name)
        unit.source_code = annotate_source(source, class_name)
        unit.metadata = extract_metadata_from_source(source, class_name)
        unit.dependencies = extract_dependencies(source, class_name)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract job #{file_path}: #{e.message}")
        nil
      end

      # Extract a job from its class (runtime introspection)
      #
      # @param job_class [Class] The job class
      # @return [ExtractedUnit, nil] The extracted unit
      def extract_job_class(job_class)
        return nil if job_class.name.nil?

        file_path = source_file_for(job_class)
        source = file_path && File.exist?(file_path) ? File.read(file_path) : ''

        unit = ExtractedUnit.new(
          type: :job,
          identifier: job_class.name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(job_class.name)
        unit.source_code = annotate_source(source, job_class.name)
        unit.metadata = extract_metadata_from_class(job_class, source)
        unit.dependencies = extract_dependencies(source, job_class.name)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract job #{job_class.name}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Class Discovery
      # ──────────────────────────────────────────────────────────────────────

      def extract_class_name(file_path, source)
        # Try to extract from source
        return ::Regexp.last_match(1) if source =~ /^\s*class\s+([\w:]+)/

        # Fall back to convention
        file_path
          .sub("#{Rails.root}/", '')
          .sub(%r{^app/(jobs|workers|sidekiq)/}, '')
          .sub('.rb', '')
          .camelize
      end

      def job_file?(source)
        # Check if this looks like a job/worker file
        source.match?(/< ApplicationJob/) ||
          source.match?(/< ActiveJob::Base/) ||
          source.match?(/include Sidekiq::Worker/) ||
          source.match?(/include Sidekiq::Job/) ||
          source.match?(/def perform/)
      end

      # Locate the source file for a job class.
      #
      # Convention path first, then introspection via {#resolve_source_location}
      # which filters out vendor/node_modules paths.
      #
      # @param job_class [Class]
      # @return [String, nil]
      def source_file_for(job_class)
        convention_path = Rails.root.join("app/jobs/#{job_class.name.underscore}.rb").to_s
        return convention_path if File.exist?(convention_path)

        resolve_source_location(job_class, app_root: Rails.root.to_s, fallback: convention_path)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      def annotate_source(source, class_name)
        job_type = detect_job_type(source)
        queue = extract_queue(source)

        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Job: #{class_name.ljust(62)}║
          # ║ Type: #{job_type.to_s.ljust(61)}║
          # ║ Queue: #{(queue || 'default').ljust(60)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

          #{source}
        ANNOTATION
      end

      def detect_job_type(source)
        return :sidekiq if source.match?(/include Sidekiq::(Worker|Job)/)
        return :active_job if source.match?(/< (ApplicationJob|ActiveJob::Base)/)
        return :good_job if source.match?(/include GoodJob/)
        return :delayed_job if source.match?(/delay|handle_asynchronously/)

        :unknown
      end

      def extract_queue(source)
        # ActiveJob style
        return ::Regexp.last_match(1) if source =~ /queue_as\s+[:"'](\w+)/

        # Sidekiq style
        return ::Regexp.last_match(1) if source =~ /sidekiq_options.*queue:\s*[:"'](\w+)/

        nil
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction (from source)
      # ──────────────────────────────────────────────────────────────────────

      def extract_metadata_from_source(source, class_name)
        {
          job_type: detect_job_type(source),
          queue: extract_queue(source),

          # Configuration
          sidekiq_options: extract_sidekiq_options(source),
          retry_config: extract_retry_config(source),
          concurrency_controls: extract_concurrency(source),

          # Interface
          perform_params: extract_perform_params(source),
          scheduled: source.match?(/perform_later|perform_in|perform_at/),

          # Error handling
          discard_on: extract_discard_on(source),
          retry_on: extract_retry_on(source),

          # Callbacks
          callbacks: extract_callbacks(source),

          # Job chaining
          enqueues_jobs: extract_enqueued_jobs(source, class_name),

          # Metrics
          loc: source.lines.count { |l| l.strip.present? && !l.strip.start_with?('#') }
        }
      end

      def extract_metadata_from_class(job_class, source)
        base_metadata = extract_metadata_from_source(source, job_class.name)

        # Enhance with runtime introspection if available
        base_metadata[:queue] ||= job_class.queue_name if job_class.respond_to?(:queue_name)

        base_metadata[:sidekiq_options] = job_class.sidekiq_options_hash if job_class.respond_to?(:sidekiq_options_hash)

        base_metadata
      end

      def extract_sidekiq_options(source)
        options = {}

        if source =~ /sidekiq_options\s+(.+)/
          opts_str = ::Regexp.last_match(1)
          opts_str.scan(/(\w+):\s*([^,\n]+)/) do |key, value|
            options[key.to_sym] = value.strip
          end
        end

        options
      end

      def extract_retry_config(source)
        config = {}

        # ActiveJob retry_on
        source.scan(/retry_on\s+(\w+)(?:,\s*wait:\s*([^,\n]+))?(?:,\s*attempts:\s*(\d+))?/) do |error, wait, attempts|
          config[:retry_on] ||= []
          config[:retry_on] << {
            error: error,
            wait: wait,
            attempts: attempts&.to_i
          }
        end

        # Sidekiq retries
        config[:sidekiq_retries] = ::Regexp.last_match(1) if source =~ /sidekiq_options.*retry:\s*(\d+|false|true)/

        config
      end

      def extract_concurrency(source)
        controls = {}

        # Sidekiq unique jobs
        controls[:unique_for] = ::Regexp.last_match(1).to_i if source =~ /unique_for:\s*(\d+)/

        # Sidekiq rate limiting
        controls[:rate_limit] = ::Regexp.last_match(1) if source =~ /rate_limit:\s*\{([^}]+)\}/

        controls
      end

      def extract_perform_params(source)
        return [] unless source =~ /def\s+perform\s*\(([^)]*)\)/

        params_str = ::Regexp.last_match(1)
        params = []

        params_str.scan(/(\*?\*?\w+)(?:\s*=\s*([^,]+))?/) do |name, default|
          params << {
            name: name.gsub(/^\*+/, ''),
            splat: if name.start_with?('**')
                     :double
                   else
                     (name.start_with?('*') ? :single : nil)
                   end,
            has_default: !default.nil?
          }
        end

        params
      end

      def extract_discard_on(source)
        source.scan(/discard_on\s+(\w+(?:::\w+)*)/).flatten
      end

      def extract_retry_on(source)
        source.scan(/retry_on\s+(\w+(?:::\w+)*)/).flatten
      end

      def extract_callbacks(source)
        callbacks = []

        %w[before_enqueue after_enqueue before_perform after_perform around_perform].each do |cb|
          source.scan(/#{cb}\s+(?::(\w+)|do)/) do |method|
            callbacks << { type: cb, method: method&.first }
          end
        end

        callbacks
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_dependencies(source, current_class_name = nil)
        # Scan standard dep types individually (not scan_common_dependencies) so we can
        # handle job deps with the richer :job_enqueue via and self-reference exclusion.
        deps = scan_model_dependencies(source)
        deps.concat(scan_service_dependencies(source))
        deps.concat(scan_mailer_dependencies(source))

        # Job-to-job dependencies with specific :job_enqueue via and self-reference exclusion
        extract_enqueued_jobs(source, current_class_name).each do |job_name|
          deps << { type: :job, target: job_name, via: :job_enqueue }
        end

        # External services
        if source.match?(/HTTParty|Faraday|RestClient|Net::HTTP/)
          deps << { type: :external, target: :http_api, via: :code_reference }
        end

        deps << { type: :infrastructure, target: :redis, via: :code_reference } if source.match?(/Redis\.current|REDIS/)

        deps.uniq { |d| [d[:type], d[:target]] }
      end

      # Scan source for job class enqueue calls and return the list of enqueued job names.
      #
      # @param source [String] The job source code
      # @param current_class_name [String, nil] The current job class name (excluded from results)
      # @return [Array<String>] Unique list of enqueued job class names
      def extract_enqueued_jobs(source, current_class_name = nil)
        pattern = /(\w+Job)\.(?:perform_later|perform_async|perform_in|perform_at|set\b)/
        job_names = source.scan(pattern).flatten.uniq
        job_names.reject { |name| name == current_class_name }
      end
    end
  end
end
