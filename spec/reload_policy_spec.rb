# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'
require 'woods/reload_policy'

RSpec.describe Woods::ReloadPolicy do
  subject(:policy) { described_class.new }

  describe '#classify' do
    context 'with boot-captured state' do
      it 'demands a restart for dependency changes' do
        expect(policy.classify('Gemfile')).to eq(:restart)
        expect(policy.classify('Gemfile.lock')).to eq(:restart)
      end

      it 'demands a restart for initializers and environment config' do
        expect(policy.classify('config/initializers/redis.rb')).to eq(:restart)
        expect(policy.classify('config/environments/development.rb')).to eq(:restart)
        expect(policy.classify('config/application.rb')).to eq(:restart)
      end

      # These were captured as boot inputs for freshness but classified
      # :ignore, so a resident process kept serving config values the file no
      # longer sets (F3). Generic config/*.rb stays :ignore here: only the
      # process that booted knows which helpers it loaded (see Daemon).
      it 'demands a restart for the Rakefile, config.ru and root gemspecs' do
        expect(policy.classify('Rakefile')).to eq(:restart)
        expect(policy.classify('config.ru')).to eq(:restart)
        expect(policy.classify('woods.gemspec')).to eq(:restart)
        expect(policy.classify('config/time_zone.rb')).to eq(:ignore)
        expect(policy.classify('packs/billing/billing.gemspec')).to eq(:ignore)
        expect(policy.classify('lib/tasks/woods.rake')).to eq(:reextract)
      end

      it 'demands a restart for schema changes' do
        expect(policy.classify('db/schema.rb')).to eq(:restart)
        expect(policy.classify('db/structure.sql')).to eq(:restart)
      end
    end

    context 'with autoloaded code' do
      it 'demands a reload for application classes' do
        expect(policy.classify('app/models/user.rb')).to eq(:reload)
        expect(policy.classify('app/services/checkout.rb')).to eq(:reload)
        expect(policy.classify('app/models/concerns/auditable.rb')).to eq(:reload)
      end

      it 'demands a reload for autoloadable lib code' do
        expect(policy.classify('lib/reporting/csv_writer.rb')).to eq(:reload)
      end

      it 'demands a reload for the route set' do
        expect(policy.classify('config/routes.rb')).to eq(:reload)
        expect(policy.classify('config/routes/admin.rb')).to eq(:reload)
      end
    end

    context 'with files read as bytes' do
      it 'only needs re-extraction for rake tasks, which are never autoloaded' do
        expect(policy.classify('lib/tasks/export.rake')).to eq(:reextract)
        expect(policy.classify('lib/tasks/export.rb')).to eq(:reextract)
      end

      it 'only needs re-extraction for locales, migrations, views and tests' do
        expect(policy.classify('config/locales/en.yml')).to eq(:reextract)
        expect(policy.classify('db/migrate/20240101000000_create_posts.rb')).to eq(:reextract)
        expect(policy.classify('db/views/reports_v01.sql')).to eq(:reextract)
        expect(policy.classify('spec/models/post_spec.rb')).to eq(:reextract)
        expect(policy.classify('test/models/post_test.rb')).to eq(:reextract)
      end

      it 'only needs re-extraction for generators, which LibExtractor reads as files' do
        expect(policy.classify('lib/generators/thing/thing_generator.rb')).to eq(:reextract)
        expect(policy.classify('lib/generators/thing/templates/thing.rb')).to eq(:reextract)
      end

      it 'only needs re-extraction for seed, deploy and importmap files' do
        %w[db/seeds.rb db/seeds/widgets.rb config/deploy.rb config/deploy/production.rb
           config/importmap.rb].each do |path|
          expect(policy.classify(path)).to eq(:reextract), path
        end
      end

      it 'only needs re-extraction for YAML config files boot does not capture' do
        %w[config/namespaces.yml config/blocked_words.yml config/settings/extra/rates.yml
           app/data/surveys/nps.yml].each do |path|
          expect(policy.classify(path)).to eq(:reextract), path
        end
      end

      it 'still demands a restart for boot-captured YAML and never reads a secret file as bytes' do
        %w[config/settings.yml config/settings/production.yml config/cable.yml config/storage.yml
           config/database.yml config/credentials.yml.enc].each do |path|
          expect(policy.classify(path)).to eq(:restart), path
        end
        expect(policy.classify('config/secrets.yml')).to eq(:ignore)
      end

      it 'follows config.config_file_paths' do
        original = Woods.configuration
        Woods.configuration = Woods::Configuration.new
        Woods.configuration.config_file_paths = ['data/**/*.yaml']

        expect(policy.classify('data/ledgers/rates.yaml')).to eq(:reextract)
        expect(policy.classify('config/namespaces.yml')).to eq(:ignore)
      ensure
        Woods.configuration = original
      end

      it 'only needs re-extraction for templates, which are not constants' do
        expect(policy.classify('app/views/posts/index.html.erb')).to eq(:reextract)
      end

      it 'only needs re-extraction for schedule files Sidekiq does not read at boot' do
        Woods::Extractors::ScheduledJobExtractor::SCHEDULE_FILES.each_key do |path|
          expected = path == 'config/sidekiq.yml' ? :restart : :reextract
          expect(policy.classify(path)).to eq(expected), path
        end
        expect(policy.classify('config/schedule.yml')).to eq(:reextract)
      end
    end

    it 'ignores paths that are not extraction input' do
      expect(policy.classify('README.md')).to eq(:ignore)
      expect(policy.classify('.github/workflows/ci.yml')).to eq(:ignore)
      expect(policy.classify('app/assets/stylesheets/application.css')).to eq(:ignore)
      expect(policy.classify('public/favicon.ico')).to eq(:ignore)
      expect(policy.classify('config/puma.rb')).to eq(:ignore)
      expect(policy.classify('deploy/chart/values.yml')).to eq(:ignore)
    end

    context 'with GraphQL operation documents' do
      it 're-extracts a document under a configured root' do
        expect(policy.classify('app/javascript/widgets/widget_list.graphql')).to eq(:reextract)
        expect(policy.classify('app/frontend/widgets/create_widget.gql')).to eq(:reextract)
      end

      it 'ignores a document outside the roots and other client files' do
        expect(policy.classify('docs/widget_list.graphql')).to eq(:ignore)
        expect(policy.classify('app/javascript/widgets/widget_list.ts')).to eq(:ignore)
        expect(policy.classify('app/javascript/node_modules/pkg/widget_list.graphql')).to eq(:ignore)
      end

      it 'follows config.graphql_document_paths' do
        original = Woods.configuration
        Woods.configuration = Woods::Configuration.new
        Woods.configuration.graphql_document_paths = ['client/**/*.graphql']

        expect(policy.classify('client/widgets/widget_list.graphql')).to eq(:reextract)
        expect(policy.classify('app/javascript/widgets/widget_list.graphql')).to eq(:ignore)
      ensure
        Woods.configuration = original
      end
    end

    context 'with Packwerk package files (#280)' do
      it 'demands a re-extraction, not a reload or restart' do
        expect(policy.classify('package.yml')).to eq(:reextract)
        expect(policy.classify('packs/billing/package.yml')).to eq(:reextract)
        expect(policy.classify('packwerk.yml')).to eq(:reextract)
      end
    end
  end

  describe '#classify_all' do
    it 'returns the strongest action any path demands' do
      expect(policy.classify_all(%w[README.md app/models/user.rb])).to eq(:reload)
      expect(policy.classify_all(%w[app/models/user.rb config/initializers/redis.rb])).to eq(:restart)
      expect(policy.classify_all(%w[config/locales/en.yml README.md])).to eq(:reextract)
    end

    it 'returns :ignore for an empty or irrelevant set' do
      expect(policy.classify_all([])).to eq(:ignore)
      expect(policy.classify_all(%w[README.md CHANGELOG.md])).to eq(:ignore)
    end
  end

  describe '#paths_requiring' do
    it 'partitions a change set by action' do
      paths = %w[
        app/models/user.rb
        config/initializers/redis.rb
        config/locales/en.yml
        README.md
      ]

      expect(policy.paths_requiring(paths, :restart)).to eq(['config/initializers/redis.rb'])
      expect(policy.paths_requiring(paths, :reload)).to eq(['app/models/user.rb'])
      expect(policy.paths_requiring(paths, :reextract)).to eq(['config/locales/en.yml'])
      expect(policy.paths_requiring(paths, :ignore)).to eq(['README.md'])
    end
  end

  # Anything a PathDispatcher rule claims is extraction input, so the policy
  # must not classify it :ignore — a daemon that skipped those paths would
  # leave the index stale with no signal.
  describe 'agreement with PathDispatcher' do
    let(:dispatcher) { Woods::PathDispatcher.new }

    # Derived from the rules themselves rather than hand-picked, so a rule added
    # for a new extractor is covered without anyone remembering to extend a list
    # here. A hand-written sample set can only ever assert about the dispatch
    # that existed when it was written — and with a `next unless relevant?`
    # guard in front of it, samples that stop matching go quiet instead of
    # failing, so the example can decay to zero assertions while still passing.
    #
    # One synthesized path per rule: the first directory it claims, the first
    # extension it accepts, and any segment it requires.
    def sample_for(rule)
      return rule.exact_paths.first if rule.exact_paths&.any?

      dir = rule.dirs.to_a.first
      return nil if dir.nil?

      extension = rule.extensions.to_a.first || '.rb'
      segment = rule.require_segment
      leaf = "woods_sample#{extension}"
      [dir, segment, leaf].compact.join('/')
    end

    def dispatch_samples
      (Woods::PathDispatcher.file_rules + Woods::PathDispatcher.whole_app_rules)
        .filter_map { |rule| sample_for(rule) }
        .uniq
    end

    it 'covers every dispatch rule with at least one sample' do
      # Guards the derivation above: if a rule shape appears that sample_for
      # cannot synthesize a matching path for, this fails rather than silently
      # narrowing the example below.
      uncovered = dispatch_samples.reject { |path| dispatcher.relevant?(path) }

      expect(uncovered).to(be_empty, "no dispatchable sample synthesized for: #{uncovered.inspect}")
    end

    it 'never ignores a path some dispatch rule claims' do
      dispatchable = dispatch_samples.select { |path| dispatcher.relevant?(path) }
      expect(dispatchable).not_to be_empty

      ignored = dispatchable.select { |path| policy.classify(path) == :ignore }

      expect(ignored).to(be_empty, "dispatchable but classified :ignore: #{ignored.inspect}")
    end
  end
end
