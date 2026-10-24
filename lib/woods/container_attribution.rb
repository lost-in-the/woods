# frozen_string_literal: true

module Woods
  # Container attribution (W-9, #759): which runtime container of the
  # application a unit belongs to, at the C4 container level. Published as
  # `metadata[:container]` and, as its `kind`, on the unit's graph node.
  #
  # The attribution is a pure function of the unit's type and the facts its
  # extractor already recorded (a job's queue and adapter override, a
  # mailer's delivery method, a model's or table's database), so a full and
  # an incremental run attribute identically. It is logical, not physical:
  # how many processes run, and where, is not a Woods concern.
  #
  # Kinds:
  # - `web`: the request process (controllers, views, components, routes,
  #   middleware, helpers, GraphQL, cable channels, front-end modules)
  # - `jobs`: the job runner (jobs, scheduled jobs, mailers). `queue` is the
  #   job's queue. `adapter` appears only when the job does not use the
  #   application's adapter: a class-level `queue_adapter` override, or a
  #   native Sidekiq worker; otherwise the adapter is the
  #   `background_processing` adapter of the BehavioralProfile unit. A
  #   mailer carries its `delivery` method.
  # - `database`: models, tables and views, with the `database` they belong to
  # - `shared`: application code every process loads (concerns, services,
  #   POROs, libs, serializers, policies, ...)
  # - `tasks`: rake tasks
  #
  # Framework sources, tests, factories, documentation, configuration,
  # migrations, engines, packages and external consumers have no container.
  module ContainerAttribution
    WEB = %i[
      controller view_template component view_component route middleware helper action_cable_channel
      graphql_type graphql_mutation graphql_resolver graphql_query graphql_operation js_module
    ].freeze
    JOBS = %i[job scheduled_job mailer].freeze
    DATABASE = %i[model database_table database_view].freeze
    SHARED = %i[
      concern service poro lib manager interactor serializer validator decorator policy pundit_policy
      state_machine event
    ].freeze
    TASKS = %i[rake_task].freeze
    # Every unit type that has a container: the application's own code.
    APPLICATION_TYPES = (WEB + JOBS + DATABASE + SHARED + TASKS).freeze

    module_function

    # @param unit [ExtractedUnit]
    # @return [Hash{Symbol => String}, nil] the container, or nil for a unit outside every container
    def for(unit)
      type = unit.type.to_sym
      metadata = unit.metadata.is_a?(Hash) ? unit.metadata : {}
      return { kind: 'web' } if WEB.include?(type)
      return job(type, metadata) if JOBS.include?(type)
      return compact(kind: 'database', database: metadata[:database]) if DATABASE.include?(type)
      return { kind: 'shared' } if SHARED.include?(type)

      { kind: 'tasks' } if TASKS.include?(type)
    end

    # Set or clear `metadata[:container]`. The key is deleted rather than set
    # to nil, so a unit outside every container serializes as before.
    #
    # @param unit [ExtractedUnit]
    # @return [Hash, nil] the container
    def annotate(unit)
      container = self.for(unit)
      if container
        unit.metadata[:container] = container
      else
        unit.metadata.delete(:container)
      end
      container
    end

    # @return [Hash]
    def job(type, metadata)
      return compact(kind: 'jobs', delivery: metadata[:delivery_method]) if type == :mailer
      return { kind: 'jobs' } if type == :scheduled_job

      adapter = metadata[:queue_adapter] || ('sidekiq' if metadata[:job_type].to_s == 'sidekiq')
      compact(kind: 'jobs', queue: metadata[:queue], adapter: adapter)
    end

    # @return [Hash{Symbol => String}] the given values as strings, nils omitted
    def compact(values)
      values.each_with_object({}) { |(key, value), out| out[key] = value.to_s unless value.nil? || value.to_s.empty? }
    end
    private_class_method :job, :compact
  end
end
