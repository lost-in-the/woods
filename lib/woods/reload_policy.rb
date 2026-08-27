# frozen_string_literal: true

module Woods
  # What a resident, booted Woods process must do before a changed path can be
  # re-extracted truthfully.
  #
  # Extraction reads the *runtime*: `ActiveRecord::Base.descendants`,
  # `Rails.application.routes`, resolved `config` values, callback chains on
  # loaded classes. So "the file changed" is not the same question as "what do
  # I have to do before re-reading it is worth anything". Three answers matter,
  # in increasing cost:
  #
  # * `:reextract` — Woods reads this file's bytes, not a constant.
  #   Re-extract; no Rails machinery has to run first.
  # * `:reload` — an autoloaded constant changed. Reload through
  #   `Rails.application.reloader` first, or the extractor introspects the
  #   class that is already gone.
  # * `:restart` — boot-captured state changed. No reloader re-runs it, so
  #   the process itself has to go.
  #
  # `:ignore` is the fourth answer and the common case: most of a repository
  # is not extraction input at all.
  #
  # ## Why `:restart` is a real category
  #
  # Rails' reloader replaces autoloaded constants. It does not re-run
  # initializers, re-read `config/*`, re-resolve `Rails.application.config`,
  # or rebuild the schema cache. Woods captures all of those:
  # `BehavioralProfile` introspects resolved config, `MiddlewareExtractor`
  # reads the built middleware stack, model extraction reads column
  # information. `rails/spring`'s well-documented staleness bugs came from
  # exactly this — under-scoping the restart set — so the boundary here is
  # drawn on the generous side.
  #
  # ## Version notes (railties >= 6.0)
  #
  # The classification is deliberately version-independent. Zeitwerk is the
  # only autoloader from 6.0 on, and every path class below has meant the same
  # thing throughout that range. Two version-sensitive behaviours sit *behind*
  # the classification rather than in it, and belong to whoever implements the
  # reload step:
  #
  # * `ActiveSupport::DescendantsTracker` internals changed across 6.0–8.x, so
  #   a reload can leave stale entries in a descendants set. Discovery-based
  #   extraction should re-read descendants *after* the reload completes, never
  #   across it.
  # * A schema change needs `reset_column_information` plus schema-cache
  #   invalidation to be visible. That is classified `:restart` here rather
  #   than `:reload` because getting it right in-process is subtle and the
  #   payoff is small — schema changes are rare and already expensive.
  #
  # @example Deciding what a batch of file events requires
  #   policy = Woods::ReloadPolicy.new
  #   policy.classify_all(%w[app/models/user.rb config/initializers/redis.rb])
  #   # => :restart
  #
  class ReloadPolicy
    # Ordered least to most disruptive. {#classify_all} returns the last one
    # any path in the set demands.
    ACTIONS = %i[ignore reextract reload restart].freeze

    # Exact paths whose change invalidates boot-captured state.
    RESTART_PATHS = %w[
      Gemfile
      Gemfile.lock
      .ruby-version
      config/application.rb
      config/boot.rb
      config/environment.rb
      config/database.yml
      config/credentials.yml.enc
      config/master.key
      db/schema.rb
      db/structure.sql
    ].freeze

    # Boot-captured configuration that is not under an initializer directory.
    #
    # `BehavioralProfile` introspects *resolved* `Rails.application.config`, and
    # these are the files that feed it outside `config/initializers`: the
    # `config` gem's settings, and the per-adapter YAML Rails reads at boot.
    # They were classified `:ignore`, which is precisely the Spring-style
    # under-scoping this file's own commentary warns against — a daemon that
    # ignores them keeps serving a profile derived from the previous values.
    #
    # `.env` files are matched by prefix rather than listed, because dotenv
    # conventionally ships `.env`, `.env.local`, `.env.development` and friends.
    # They also have to survive the watcher's dotfile filter to be seen at all.
    # Named rather than wildcarded, deliberately. `config/*.yml` also catches
    # files Woods reads as *bytes* — `config/recurring.yml` and
    # `config/sidekiq_cron.yml` are scheduled-job sources, and escalating
    # either to `:restart` would stop the daemon for a change it could simply
    # re-extract. The boot-captured set is small and knowable; guessing at it
    # costs more than listing it.
    RESTART_PATH_PATTERNS = [
      %r{\Aconfig/settings\.ya?ml\z},
      %r{\Aconfig/settings/[^/]+\.ya?ml\z},
      # Note what is absent: `config/recurring.yml` and `config/sidekiq_cron.yml`
      # are scheduled-job *sources* that Woods reads as bytes
      # (`ScheduledJobExtractor::SCHEDULE_FILES`), so they stay `:reextract`.
      # `spec/reload_policy_spec.rb` asserts that, which is how the first draft
      # of this list got caught.
      %r{\Aconfig/(cable|storage|sidekiq|puma|cache|queue)\.ya?ml\z},
      /\A\.env(\..+)?\z/
    ].freeze

    # Directory prefixes whose change invalidates boot-captured state.
    RESTART_DIRECTORIES = %w[
      config/initializers
      config/environments
      config/credentials
    ].freeze

    # Directories holding autoloaded application code. A `.rb` change here
    # redefines a constant the extractors introspect.
    RELOAD_DIRECTORIES = %w[app lib].freeze

    # Route definitions. Reloading the route set is cheaper than a full
    # reload (`Rails.application.reload_routes!`), but it is still a runtime
    # refresh rather than a file re-read, so it lands in the same bucket.
    ROUTE_PATHS = %w[config/routes.rb].freeze
    ROUTE_DIRECTORIES = %w[config/routes].freeze

    # Directories Woods reads as bytes. No constant is involved, so no Rails
    # machinery has to run before re-extraction.
    REEXTRACT_DIRECTORIES = %w[
      app/views
      config/locales
      db/migrate
      db/views
      lib/tasks
      spec
      test
    ].freeze

    # Schedule files, which are data rather than code.
    REEXTRACT_PATHS = %w[
      config/recurring.yml
      config/sidekiq_cron.yml
      config/schedule.rb
    ].freeze

    # What has to happen before this path can be re-extracted truthfully.
    #
    # @param relative_path [String] Rails.root-relative path
    # @return [Symbol] one of {ACTIONS}
    def classify(relative_path)
      path = relative_path.to_s
      return :restart if restart?(path)
      return :reload if reload?(path)
      return :reextract if reextract?(path)

      :ignore
    end

    # The strongest action any path in the set demands.
    #
    # @param relative_paths [Enumerable<String>]
    # @return [Symbol] one of {ACTIONS}
    def classify_all(relative_paths)
      Array(relative_paths).reduce(:ignore) do |strongest, path|
        stronger_of(strongest, classify(path))
      end
    end

    # Paths in the set that demand a given action.
    #
    # @param relative_paths [Enumerable<String>]
    # @param action [Symbol] one of {ACTIONS}
    # @return [Array<String>]
    def paths_requiring(relative_paths, action)
      Array(relative_paths).select { |path| classify(path) == action }
    end

    private

    def stronger_of(left, right)
      ACTIONS.index(left) >= ACTIONS.index(right) ? left : right
    end

    def restart?(path)
      RESTART_PATHS.include?(path) || under?(path, RESTART_DIRECTORIES) ||
        RESTART_PATH_PATTERNS.any? { |pattern| pattern.match?(path) }
    end

    def reload?(path)
      return true if ROUTE_PATHS.include?(path) || under?(path, ROUTE_DIRECTORIES)
      # lib/tasks and lib/generators are read as files, never autoloaded.
      return false if under?(path, %w[lib/tasks lib/generators])

      path.end_with?('.rb') && under?(path, RELOAD_DIRECTORIES)
    end

    def reextract?(path)
      REEXTRACT_PATHS.include?(path) || under?(path, REEXTRACT_DIRECTORIES)
    end

    def under?(path, directories)
      directories.any? { |dir| path.start_with?("#{dir}/") }
    end
  end
end
