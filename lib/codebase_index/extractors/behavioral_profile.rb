# frozen_string_literal: true

module CodebaseIndex
  module Extractors
    # BehavioralProfile introspects resolved Rails.application.config values
    # to produce a single ExtractedUnit summarizing the app's runtime
    # behavioral configuration.
    #
    # Sections extracted (each independently guarded):
    # - Database: adapter, schema_format, belongs_to_required, has_many_inversing
    # - Frameworks: ActionCable, ActiveStorage, ActionMailbox, ActionText, Turbo, Stimulus, SolidQueue, SolidCache
    # - Behavior flags: api_only, eager_load, time_zone, strong params action, session store, filter params
    # - Background processing: active_job queue_adapter
    # - Caching: cache_store type
    # - Email: delivery_method
    #
    # @example
    #   profile = BehavioralProfile.new
    #   unit = profile.extract
    #   unit.metadata[:database][:adapter] #=> "postgresql"
    #
    class BehavioralProfile
      # Frameworks to detect via `defined?` checks
      FRAMEWORK_CHECKS = {
        action_cable: 'ActionCable',
        active_storage: 'ActiveStorage',
        action_mailbox: 'ActionMailbox',
        action_text: 'ActionText',
        turbo: 'Turbo',
        stimulus_reflex: 'StimulusReflex',
        solid_queue: 'SolidQueue',
        solid_cache: 'SolidCache'
      }.freeze

      # Extract a behavioral profile from the current Rails application.
      #
      # @return [ExtractedUnit, nil] A single configuration unit, or nil on catastrophic failure
      def extract
        config = Rails.application.config

        profile = {
          config_type: 'behavioral_profile',
          rails_version: Rails.version,
          ruby_version: RUBY_VERSION,
          database: extract_database(config),
          frameworks_active: extract_frameworks,
          behavior_flags: extract_behavior_flags(config),
          background_processing: extract_background(config),
          caching: extract_caching(config),
          email: extract_email(config)
        }

        build_unit(profile)
      rescue StandardError => e
        Rails.logger.error("BehavioralProfile extraction failed: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Database
      # ──────────────────────────────────────────────────────────────────────

      # Extract database configuration from ActiveRecord.
      #
      # @param config [Rails::Application::Configuration]
      # @return [Hash]
      def extract_database(config)
        return {} unless defined?(ActiveRecord::Base)

        result = {}

        if ActiveRecord::Base.respond_to?(:connection_db_config)
          result[:adapter] = ActiveRecord::Base.connection_db_config.adapter
        end

        if config.respond_to?(:active_record)
          ar = config.active_record
          result[:schema_format] = ar.schema_format if ar.respond_to?(:schema_format)
          if ar.respond_to?(:belongs_to_required_by_default)
            result[:belongs_to_required_by_default] = ar.belongs_to_required_by_default
          end
          result[:has_many_inversing] = ar.has_many_inversing if ar.respond_to?(:has_many_inversing)
        end

        result
      rescue StandardError => e
        Rails.logger.error("BehavioralProfile database section failed: #{e.message}")
        {}
      end

      # ──────────────────────────────────────────────────────────────────────
      # Frameworks
      # ──────────────────────────────────────────────────────────────────────

      # Detect which optional frameworks are loaded.
      #
      # @return [Hash]
      def extract_frameworks
        FRAMEWORK_CHECKS.transform_values do |constant_name|
          Object.const_defined?(constant_name)
        end
      rescue StandardError => e
        Rails.logger.error("BehavioralProfile frameworks section failed: #{e.message}")
        {}
      end

      # ──────────────────────────────────────────────────────────────────────
      # Behavior flags
      # ──────────────────────────────────────────────────────────────────────

      # Extract behavior flags from Rails config.
      #
      # @param config [Rails::Application::Configuration]
      # @return [Hash]
      def extract_behavior_flags(config)
        flags = {}

        safe_read(config, :api_only) { |v| flags[:api_only] = v }
        safe_read(config, :eager_load) { |v| flags[:eager_load] = v }
        safe_read(config, :time_zone) { |v| flags[:time_zone] = v }
        safe_read(config, :session_store) { |v| flags[:session_store] = v }
        safe_read(config, :filter_parameters) { |v| flags[:filter_parameters] = v }

        if config.respond_to?(:action_controller)
          ac = config.action_controller
          if ac.respond_to?(:action_on_unpermitted_parameters)
            flags[:action_on_unpermitted_parameters] = ac.action_on_unpermitted_parameters
          end
        end

        flags
      rescue StandardError => e
        Rails.logger.error("BehavioralProfile behavior_flags section failed: #{e.message}")
        {}
      end

      # ──────────────────────────────────────────────────────────────────────
      # Background processing
      # ──────────────────────────────────────────────────────────────────────

      # Extract background processing configuration.
      #
      # @param config [Rails::Application::Configuration]
      # @return [Hash]
      def extract_background(config)
        return {} unless config.respond_to?(:active_job)

        aj = config.active_job
        return {} unless aj.respond_to?(:queue_adapter)

        { adapter: aj.queue_adapter }
      rescue StandardError => e
        Rails.logger.error("BehavioralProfile background section failed: #{e.message}")
        {}
      end

      # ──────────────────────────────────────────────────────────────────────
      # Caching
      # ──────────────────────────────────────────────────────────────────────

      # Extract caching configuration.
      #
      # @param config [Rails::Application::Configuration]
      # @return [Hash]
      def extract_caching(config)
        return {} unless config.respond_to?(:cache_store)

        raw = config.cache_store
        store = raw.is_a?(Array) ? raw.first : raw

        { store: store }
      rescue StandardError => e
        Rails.logger.error("BehavioralProfile caching section failed: #{e.message}")
        {}
      end

      # ──────────────────────────────────────────────────────────────────────
      # Email
      # ──────────────────────────────────────────────────────────────────────

      # Extract email delivery configuration.
      #
      # @param config [Rails::Application::Configuration]
      # @return [Hash]
      def extract_email(config)
        return {} unless config.respond_to?(:action_mailer)

        am = config.action_mailer
        return {} unless am.respond_to?(:delivery_method)

        { delivery_method: am.delivery_method }
      rescue StandardError => e
        Rails.logger.error("BehavioralProfile email section failed: #{e.message}")
        {}
      end

      # ──────────────────────────────────────────────────────────────────────
      # Unit construction
      # ──────────────────────────────────────────────────────────────────────

      # Build the ExtractedUnit from the assembled profile hash.
      #
      # @param profile [Hash]
      # @return [ExtractedUnit]
      def build_unit(profile)
        unit = ExtractedUnit.new(
          type: :configuration,
          identifier: 'BehavioralProfile',
          file_path: Rails.root.join('config/application.rb').to_s
        )

        unit.namespace = 'behavioral_profile'
        unit.metadata = profile
        unit.source_code = build_narrative(profile)
        unit.dependencies = build_dependencies(profile)

        unit
      end

      # Generate a human-readable narrative summary.
      #
      # @param profile [Hash]
      # @return [String]
      def build_narrative(profile)
        lines = []
        lines << '# Behavioral Profile'
        lines << "# Rails #{profile[:rails_version]} / Ruby #{profile[:ruby_version]}"
        lines << '#'

        # Database
        db = profile[:database]
        if db.any?
          lines << "# Database: #{db[:adapter] || 'unknown'}"
          lines << "#   schema_format: #{db[:schema_format]}" if db[:schema_format]
          unless db[:belongs_to_required_by_default].nil?
            lines << "#   belongs_to_required: #{db[:belongs_to_required_by_default]}"
          end
          lines << "#   has_many_inversing: #{db[:has_many_inversing]}" unless db[:has_many_inversing].nil?
        end

        # Frameworks
        active = profile[:frameworks_active].select { |_, v| v }
        if active.any?
          lines << '#'
          lines << "# Active frameworks: #{active.keys.map { |k| FRAMEWORK_CHECKS[k] || k.to_s }.join(', ')}"
        end

        # Behavior flags
        flags = profile[:behavior_flags]
        if flags.any?
          lines << '#'
          lines << '# Behavior flags:'
          flags.each { |k, v| lines << "#   #{k}: #{v}" }
        end

        # Background
        bg = profile[:background_processing]
        if bg.any?
          lines << '#'
          lines << "# Background: #{bg[:adapter]}"
        end

        # Caching
        cache = profile[:caching]
        if cache.any?
          lines << '#'
          lines << "# Cache store: #{cache[:store]}"
        end

        # Email
        email = profile[:email]
        if email.any?
          lines << '#'
          lines << "# Email delivery: #{email[:delivery_method]}"
        end

        lines.join("\n")
      end

      # Build dependency list from detected frameworks and adapters.
      #
      # @param profile [Hash]
      # @return [Array<Hash>]
      def build_dependencies(profile)
        deps = []

        profile[:frameworks_active].each do |key, active|
          next unless active

          constant_name = FRAMEWORK_CHECKS[key] || key.to_s
          deps << { type: :framework, target: constant_name, via: :behavioral_profile }
        end

        deps
      end

      # Safely read a config attribute if it responds to it.
      #
      # @param obj [Object]
      # @param method [Symbol]
      # @yield [value] Yields the value if available
      def safe_read(obj, method)
        yield obj.public_send(method) if obj.respond_to?(method)
      end
    end
  end
end
