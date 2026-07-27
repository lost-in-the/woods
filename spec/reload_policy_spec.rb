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

      it 'only needs re-extraction for templates, which are not constants' do
        expect(policy.classify('app/views/posts/index.html.erb')).to eq(:reextract)
      end

      it 'only needs re-extraction for schedule files' do
        Woods::Extractors::ScheduledJobExtractor::SCHEDULE_FILES.each_key do |path|
          expect(policy.classify(path)).to eq(:reextract)
        end
      end
    end

    it 'ignores paths that are not extraction input' do
      expect(policy.classify('README.md')).to eq(:ignore)
      expect(policy.classify('.github/workflows/ci.yml')).to eq(:ignore)
      expect(policy.classify('app/assets/stylesheets/application.css')).to eq(:ignore)
      expect(policy.classify('public/favicon.ico')).to eq(:ignore)
      # LibExtractor skips generators, so nothing downstream reads them.
      expect(policy.classify('lib/generators/thing/thing_generator.rb')).to eq(:ignore)
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

    it 'never ignores a path some dispatch rule claims' do
      samples = %w[
        app/services/checkout.rb
        app/models/user.rb
        app/views/posts/index.html.erb
        config/locales/en.yml
        config/initializers/redis.rb
        config/routes.rb
        db/migrate/20240101000000_create_posts.rb
        db/views/reports_v01.sql
        lib/tasks/export.rake
        lib/reporting/csv_writer.rb
        spec/models/post_spec.rb
        spec/factories/posts.rb
        Gemfile.lock
      ]

      samples.each do |path|
        next unless dispatcher.relevant?(path)

        expect(policy.classify(path)).not_to(eq(:ignore), "#{path} is dispatchable but classified :ignore")
      end
    end
  end
end
