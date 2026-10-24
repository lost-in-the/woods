# frozen_string_literal: true

require_relative '../source_file'
require_relative '../source_inputs/consumer_errors'

require_relative 'reference_patterns'
require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'method_effects'
require_relative 'job_ancestry'
require_relative 'job_resilience'
require_relative '../source_references/runtime_lookup'

module Woods
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
        find_files_in_directories(@directories).each do |file|
          unit = extract_job_file(file)
          units << unit if unit
        end

        # Also try class-based discovery for ActiveJob
        seen = units.to_set(&:identifier)
        discoverable_classes.each do |job_class|
          next if seen.include?(job_class.name)

          unit = extract_job_class(job_class)
          if unit
            units << unit
            seen << unit.identifier
          end
        end

        units.compact
      end

      # Job classes the runtime vouches for beyond the job-directory scan:
      # every named ApplicationJob descendant, plus every class defined in
      # the application whose ancestry includes ActiveJob::Base or a Sidekiq
      # job module ({JobAncestry.admitted?}). A job defined in a model file,
      # or a leaf that inherits everything from a parent job, is reachable
      # only this way. So is a job class a macro generated with `Class.new`
      # and `const_set` ({JobAncestry.generated_site}), which no file declares.
      #
      # Shared with the incremental path, which re-extracts a job by class
      # when re-deriving it from its file names a different constant — the
      # file's governed name is then the enclosing class, not the job.
      #
      # @return [Array<Class>] named, live job classes
      def discoverable_classes
        lookup = SourceReferences::RuntimeLookup.new
        application_jobs = defined?(ApplicationJob) ? ApplicationJob.descendants : []
        app_root = Rails.root.to_s
        @generated_sites = GeneratedJobSite.new(app_root: app_root)
        ancestry_jobs = JobAncestry.candidates.select do |klass|
          JobAncestry.admitted?(klass, app_root: app_root) || generated_site(klass)
        end
        (application_jobs + ancestry_jobs).uniq.select do |klass|
          klass.name && lookup.call("::#{klass.name}", allow_private: true)[:value].equal?(klass)
        end
      end

      # Extract a job from its file
      #
      # @param file_path [String] Path to the job file
      # @return [ExtractedUnit, nil] The extracted unit
      def extract_job_file(file_path)
        source = SourceFile.read(file_path)
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
        live = live_job_class(class_name)
        apply_runtime_resilience(unit.metadata, live) if live
        unit.dependencies = extract_dependencies(source, class_name)
        MethodEffects.apply(unit, source)

        unit
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract job #{file_path}: #{e.message}")
        nil
      end

      # Extract a job from its class (runtime introspection)
      #
      # @param job_class [Class] The job class
      # @return [ExtractedUnit, nil] The extracted unit
      def extract_job_class(job_class)
        return nil if job_class.name.nil?

        site = generated_site(job_class)
        return extract_generated_job(job_class, site) if site

        file_path = source_file_for(job_class)
        source = file_path && File.exist?(file_path) ? SourceFile.read(file_path) : ''

        unit = ExtractedUnit.new(
          type: :job,
          identifier: job_class.name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(job_class.name)
        unit.source_code = annotate_source(source, job_class.name)
        unit.metadata = extract_metadata_from_class(job_class, source)
        unit.dependencies = extract_dependencies(source, job_class.name)
        MethodEffects.apply(unit, source)

        unit
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract job #{job_class.name}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Class Discovery
      # ──────────────────────────────────────────────────────────────────────

      def extract_class_name(file_path, source)
        # Zeitwerk-governed naming (G-1), then position-aware (#174), then
        # convention.
        governed_class_name(file_path, source) || qualified_first_class_name(source) || file_path
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

      # @param job_class [Class]
      # @return [GeneratedJobSite::Site, nil] see {JobAncestry.generated_site}
      def generated_site(job_class)
        @generated_sites ||= GeneratedJobSite.new(app_root: Rails.root.to_s)
        JobAncestry.generated_site(job_class, app_root: Rails.root.to_s, resolver: @generated_sites)
      end

      # A job class no file declares. Its unit holds the declaring line(s)
      # only: the body belongs to the generator, which every class it builds
      # shares. Configuration and the perform signature therefore come from
      # the runtime class, not from source.
      #
      # @param job_class [Class]
      # @param site [GeneratedJobSite::Site]
      # @return [ExtractedUnit]
      def extract_generated_job(job_class, site)
        unit = ExtractedUnit.new(type: :job, identifier: job_class.name, file_path: site.file_path)
        metadata = generated_metadata(job_class, site)

        unit.namespace = extract_namespace(job_class.name)
        unit.source_code = annotation_banner(job_class.name, metadata[:job_type], metadata[:queue]) + site.source
        unit.metadata = metadata
        unit.dependencies = extract_dependencies(site.source, job_class.name)
        unit
      end

      def generated_metadata(job_class, site)
        metadata = extract_metadata_from_source('', job_class.name)
        options = job_class.sidekiq_options_hash if job_class.respond_to?(:sidekiq_options_hash)
        parent = job_class.superclass&.name
        metadata.merge(
          job_type: runtime_job_type(job_class) || :unknown,
          parent_class: parent == 'Object' ? nil : parent,
          queue: runtime_queue(job_class, options),
          sidekiq_options: options || {},
          perform_params: runtime_perform_params(job_class),
          loc: count_loc(site.source),
          generated: true,
          generated_by: site.generated_by,
          **{ queue_adapter: queue_adapter_override(job_class) }.compact
        )
      end

      # The queue adapter an Active Job class uses when it is not the
      # application's: a `self.queue_adapter =` on the class or an ancestor.
      # Nil for every job that follows `config.active_job.queue_adapter`, so
      # the app-wide adapter stays one fact on the BehavioralProfile unit and
      # a configuration change never leaves per-job values stale (W-9).
      #
      # @param job_class [Class]
      # @return [String, nil]
      def queue_adapter_override(job_class)
        return nil unless defined?(::ActiveJob::Base) && job_class.is_a?(Class) && job_class < ::ActiveJob::Base
        unless job_class.respond_to?(:queue_adapter_name) && ::ActiveJob::Base.respond_to?(:queue_adapter_name)
          return nil
        end

        name = job_class.queue_adapter_name.to_s
        name.empty? || name == ::ActiveJob::Base.queue_adapter_name.to_s ? nil : name
      rescue StandardError
        nil
      end

      # A queue the class states as a plain name. A queue computed by a block
      # has no stable spelling and is left out.
      def runtime_queue(job_class, sidekiq_options)
        queue = sidekiq_options.is_a?(Hash) && (sidekiq_options['queue'] || sidekiq_options[:queue])
        queue ||= job_class.queue_name if job_class.respond_to?(:queue_name)
        queue.to_s if queue.is_a?(String) || queue.is_a?(Symbol)
      end

      # The shape {#extract_perform_params} reads from source, from the method.
      def runtime_perform_params(job_class)
        return [] unless job_class.method_defined?(:perform)

        job_class.instance_method(:perform).parameters.filter_map do |kind, name|
          next if name.nil? || kind == :block

          splat = { rest: :single, keyrest: :double }[kind]
          { name: name.to_s, splat: splat, has_default: %i[opt key].include?(kind) }
        end
      end

      # Runtime ancestry, for a class whose source carries no job marker.
      #
      # @param job_class [Class]
      # @return [Symbol, nil]
      def runtime_job_type(job_class)
        return :sidekiq if JobAncestry.sidekiq_modules.any? { |mod| job_class.include?(mod) }

        :active_job if defined?(ActiveJob::Base) && job_class < ActiveJob::Base
      end

      # Locate the source file for a job class (class-discovery path only).
      #
      # Convention path under each job directory first, then introspection via {#resolve_source_location}
      # which filters out vendor/node_modules paths.
      #
      # Returns nil rather than a fabricated convention path when nothing
      # resolves — the GraphQL precedent (B-070/#171). `ApplicationJob.descendants`
      # includes gem- and engine-defined classes; registering
      # `app/jobs/<name>.rb` for one puts a nonexistent, rule-claimed path in
      # the graph's file_map, and the next incremental run's safety-net sweep
      # prunes the unit a full extraction still emits (EXTA-3). A nil path
      # never enters file_map, so the sweep cannot reach it;
      # {#extract_job_class} already reads source only when the path exists.
      #
      # @param job_class [Class]
      # @return [String, nil]
      def source_file_for(job_class)
        JOB_DIRECTORIES.each do |dir|
          convention_path = Rails.root.join(dir, "#{job_class.name.underscore}.rb").to_s
          return convention_path if File.exist?(convention_path)
        end

        resolve_source_location(job_class, app_root: Rails.root.to_s, fallback: nil)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      def annotate_source(source, class_name)
        "#{annotation_banner(class_name, detect_job_type(source), extract_queue(source))}#{source}\n"
      end

      def annotation_banner(class_name, job_type, queue)
        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Job: #{class_name.ljust(62)}║
          # ║ Type: #{job_type.to_s.ljust(61)}║
          # ║ Queue: #{(queue || 'default').ljust(60)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

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
          parent_class: extract_parent_class(source, class_name),
          queue: extract_queue(source),

          # Configuration
          sidekiq_options: extract_sidekiq_options(source),
          retry_config: extract_retry_config(source),
          concurrency_controls: extract_concurrency(source),

          # Interface
          perform_params: extract_perform_params(source),
          scheduled: source.match?(/perform_later|perform_in|perform_at/),

          # Callbacks
          callbacks: extract_callbacks(source),

          # Job chaining
          enqueues_jobs: extract_enqueued_jobs(source, class_name),

          # Metrics
          loc: source.lines.count { |l| l.strip.present? && !l.strip.start_with?('#') }
        }.merge(JobResilience.static(source, class_name))
      end

      # `retry_config`'s retry_on entries from the resilience facts (W-4).
      #
      # @param handlers [Array<Hash>] rescue_handlers
      # @return [Array<Hash>, nil] error, wait, attempts per retried exception
      def retry_entries(handlers)
        entries = handlers.select { |handler| handler[:kind] == 'retry_on' }.flat_map do |handler|
          attempts = handler[:attempts].is_a?(Integer) ? handler[:attempts] : nil
          handler[:exceptions].map { |error| { error: error, wait: handler[:wait]&.to_s, attempts: attempts } }
        end
        entries.empty? ? nil : entries
      end

      def extract_metadata_from_class(job_class, source)
        base_metadata = extract_metadata_from_source(source, job_class.name)

        # Enhance with runtime introspection if available
        base_metadata[:job_type] = runtime_job_type(job_class) || :unknown if base_metadata[:job_type] == :unknown
        base_metadata[:queue] ||= job_class.queue_name if job_class.respond_to?(:queue_name)
        adapter = queue_adapter_override(job_class)
        base_metadata[:queue_adapter] = adapter if adapter

        base_metadata[:sidekiq_options] = job_class.sidekiq_options_hash if job_class.respond_to?(:sidekiq_options_hash)
        apply_runtime_resilience(base_metadata, job_class)
      end

      # The loaded class a job file declares, when the booted app has it, so
      # its resilience facts come from the class (W-4); nil otherwise, and
      # the class-body reading stands.
      #
      # @param class_name [String]
      # @return [Class, nil]
      def live_job_class(class_name)
        value = SourceReferences::RuntimeLookup.new.call("::#{class_name}", allow_private: true)[:value]
        value if value.is_a?(Class) && value.respond_to?(:rescue_handlers)
      rescue StandardError
        nil
      end

      # Active Job classes answer from the class (inherited and concern
      # declarations included); Sidekiq workers add their retry option.
      def apply_runtime_resilience(metadata, job_class)
        if job_class.respond_to?(:rescue_handlers)
          metadata.merge!(JobResilience.runtime(job_class, root: Rails.root))
          config = (metadata[:retry_config] || {}).except(:retry_on)
          retries = retry_entries(metadata[:rescue_handlers])
          metadata[:retry_config] = retries ? { retry_on: retries }.merge(config) : config
        end
        options = metadata[:sidekiq_options]
        if options.is_a?(Hash) && (options.key?('retry') || options.key?(:retry))
          metadata[:sidekiq_retry] = options['retry'] || options[:retry]
        end
        metadata
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

        # ActiveJob retry_on comes from the class-body calls (W-4): a regex
        # over the file read comments and strings as declarations.
        retries = retry_entries(JobResilience.static(source, nil)[:rescue_handlers])
        config[:retry_on] = retries if retries

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
        MethodParameters.extract(source, :perform).map do |parameter|
          parameter.slice(:name, :splat, :has_default)
        end
      end

      def extract_callbacks(source)
        JobResilience.static_callbacks(source)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_dependencies(source, current_class_name = nil)
        source = CommentBlanking.ruby(source)
        # Scan standard dep types individually (not scan_common_dependencies) so we can
        # handle job deps with the richer :job_enqueue via and self-reference exclusion.
        deps = scan_model_dependencies(source)
        deps.concat(scan_service_dependencies(source))
        deps.concat(scan_mailer_dependencies(source))
        deps.concat(scan_config_dependencies(source))

        # Job-to-job dependencies with specific :job_enqueue via and self-reference exclusion
        extract_enqueued_jobs(source, current_class_name).each do |job_name|
          deps << { type: :job, target: job_name, via: :job_enqueue }
        end

        # External services
        if source.match?(/HTTParty|Faraday|RestClient|Net::HTTP/)
          deps << { type: :external, target: :http_api, via: :external_call }
        end

        deps << { type: :infrastructure, target: :redis, via: :code_reference } if source.match?(/Redis\.current|REDIS/)

        consolidate_dependencies(deps)
      end

      # Scan source for job class enqueue calls and return the list of enqueued job names.
      #
      # Shares {ReferencePatterns.job_enqueues} with the scanner and
      # CallbackAnalyzer so all three sites agree on what an enqueue looks
      # like — `*Worker` classes and namespaced jobs included (EXTA-2/EXTA-4).
      #
      # @param source [String] The job source code
      # @param current_class_name [String, nil] The current job class name (excluded from results)
      # @return [Array<String>] Unique list of enqueued job class names
      def extract_enqueued_jobs(source, current_class_name = nil)
        job_names = ReferencePatterns.job_enqueues(source).uniq
        job_names.reject { |name| name == current_class_name }
      end
    end
  end
end
