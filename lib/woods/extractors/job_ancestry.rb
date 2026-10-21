# frozen_string_literal: true

require_relative '../source_file'
require_relative 'shared_utility_methods'
require_relative 'generated_job_site'

module Woods
  module Extractors
    # Runtime ancestry that makes a class a job, and the admission rule the
    # job family applies to it.
    #
    # JobExtractor admits every application class whose ancestry includes
    # ActiveJob::Base or a loaded Sidekiq job module. File-scanning families
    # (PoroExtractor and its peers) consult the same rule so that such a class
    # becomes exactly one unit, a job, wherever it is defined.
    #
    # @example
    #   JobAncestry.admitted?(ImportManager, app_root: Rails.root.to_s) # => true
    module JobAncestry
      extend SharedUtilityMethods

      # Sidekiq's job modules, counted only when Sidekiq is loaded.
      # `Worker` aliases `Job` on current Sidekiq.
      SIDEKIQ_JOB_MODULES = %w[Sidekiq::Job Sidekiq::Worker].freeze

      # Unbound so a class that redefines `include?` as a class method cannot
      # answer for its ancestry.
      INCLUDES = Module.instance_method(:include?)

      class << self
        # @param klass [Object]
        # @return [Boolean] whether klass is a class with job ancestry
        def job_class?(klass)
          return false unless klass.is_a?(Class)
          return true if defined?(::ActiveJob::Base) && klass < ::ActiveJob::Base

          sidekiq_modules.any? { |mod| INCLUDES.bind_call(klass, mod) }
        end

        # Every loaded class {#job_class?} could accept, wherever defined.
        # A module has no descendants list, hence the ObjectSpace walk.
        #
        # @return [Array<Class>]
        def candidates
          jobs = defined?(::ActiveJob::Base) ? ::ActiveJob::Base.descendants : []
          modules = sidekiq_modules
          return jobs if modules.empty?

          jobs + ObjectSpace.each_object(Class).select do |klass|
            modules.any? { |mod| INCLUDES.bind_call(klass, mod) }
          end
        end

        # Whether the job family owns klass: job ancestry, an application
        # definition site, and a definition file that declares the class.
        # A class built with `Class.new` and `const_set` reports the
        # generator's call site, whose source is not the job's, so it is
        # refused here; {.generated_site} answers for it instead. Gem- and
        # engine-defined jobs are refused by the site.
        #
        # @param klass [Object]
        # @param app_root [String]
        # @return [Boolean]
        def admitted?(klass, app_root:)
          return false unless job_class?(klass)

          name = klass.name
          path = name && Object.const_source_location(name)&.first
          return false unless app_source?(path, app_root)
          return true if declares_class?(SourceFile.read(path), name)

          Rails.logger.debug "[Woods] #{path} does not declare job #{name} (generated class)"
          false
        rescue NameError, SystemCallError
          false
        end

        # Where a job class no file declares was generated: the application
        # line that called its generator. Nil for a declared class, and for a
        # class a generator outside the application bound.
        #
        # @param klass [Object]
        # @param app_root [String]
        # @param resolver [GeneratedJobSite] reused across classes to parse
        #   each file once
        # @return [GeneratedJobSite::Site, nil]
        def generated_site(klass, app_root:, resolver: GeneratedJobSite.new(app_root: app_root))
          return nil unless job_class?(klass)

          resolver.call(klass)
        end

        # @return [Array<Module>] the loaded Sidekiq job modules
        def sidekiq_modules
          SIDEKIQ_JOB_MODULES.filter_map { |name| Object.const_get(name) if Object.const_defined?(name) }.uniq
        end
      end
    end
  end
end
