# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'

RSpec.describe Woods::PathDispatcher do
  subject(:dispatcher) { described_class.new }

  def keys_for(path)
    dispatcher.file_rules_for(path).map(&:extractor_key)
  end

  describe '#file_rules_for' do
    it 'routes a service file to the service extractor' do
      expect(keys_for('app/services/checkout.rb')).to eq([:services])
    end

    it 'routes every directory a multi-directory extractor claims' do
      Woods::Extractors::ServiceExtractor::SERVICE_DIRECTORIES.each do |dir|
        expect(keys_for("#{dir}/thing.rb")).to include(:services)
      end
    end

    it 'routes a path claimed by two extractors to both' do
      # app/policies is scanned by PolicyExtractor and PunditExtractor alike.
      expect(keys_for('app/policies/post_policy.rb')).to contain_exactly(:policies, :pundit_policies)
    end

    it 'routes a nested concern outside the canonical directories' do
      expect(keys_for('app/models/gateway/stripe/concerns/retryable.rb')).to include(:concerns)
    end

    it 'routes an app/models file to the PORO and caching extractors, not to concerns' do
      keys = keys_for('app/models/value_object.rb')

      expect(keys).to include(:poros, :caching)
      expect(keys).not_to include(:concerns)
    end

    it 'keeps concerns out of the PORO extractor' do
      expect(keys_for('app/models/concerns/auditable.rb')).not_to include(:poros)
    end

    it 'routes locale YAML but not locale Ruby' do
      expect(keys_for('config/locales/en.yml')).to eq([:i18n])
      expect(keys_for('config/locales/en.rb')).to be_empty
    end

    it 'routes .rake files only' do
      expect(keys_for('lib/tasks/export.rake')).to include(:rake_tasks)
      expect(keys_for('lib/tasks/export.rb')).not_to include(:rake_tasks)
    end

    it 'excludes lib/tasks and lib/generators from the lib extractor' do
      expect(keys_for('lib/reporting/csv.rb')).to include(:libs)
      expect(keys_for('lib/tasks/export.rb')).not_to include(:libs)
      expect(keys_for('lib/generators/thing/thing_generator.rb')).not_to include(:libs)
    end

    it 'matches migrations only at the top level of db/migrate' do
      expect(keys_for('db/migrate/20240101000000_create_posts.rb')).to eq([:migrations])
      expect(keys_for('db/migrate/archive/20200101000000_old.rb')).to be_empty
    end

    it 'routes erb templates to the view template and caching extractors' do
      expect(keys_for('app/views/posts/index.html.erb')).to contain_exactly(:view_templates, :caching)
    end

    it 'routes spec and test files to test mappings by their suffix' do
      expect(keys_for('spec/models/post_spec.rb')).to eq([:test_mappings])
      expect(keys_for('test/models/post_test.rb')).to eq([:test_mappings])
      expect(keys_for('spec/support/helper.rb')).to be_empty
    end

    it 'returns nothing for a path no extractor claims' do
      expect(keys_for('README.md')).to be_empty
      expect(keys_for('config/routes.rb')).to be_empty
    end

    it 'names a real extraction method on every rule' do
      described_class.file_rules.each do |rule|
        klass = Woods::Extractor::EXTRACTORS[rule.extractor_key]
        expect(klass).not_to(be_nil, "unknown extractor key #{rule.extractor_key}")
        expect(klass.instance_methods).to(
          include(rule.method_name),
          "#{klass} has no ##{rule.method_name}"
        )
      end
    end

    # A file-based extractor with no dispatch rule at all is a silently
    # un-indexable file type: new files of that kind would never enter the
    # index (#164 gap 1). Every FILE_BASED type must therefore be reachable
    # either per-file or through a wholesale re-run.
    it 'covers every file-based unit type' do
      expect(uncovered_extractor_keys).to be_empty
    end

    # Deriving the expectation from FILE_BASED alone left a hole exactly the
    # size of the bug it was meant to prevent: GRAPHQL_TYPES is its own
    # constant (four unit types sharing one extractor method), so it was never
    # in the expected set and `app/graphql` went unrouted — new types,
    # mutations and resolvers never entered the index, which is #164 gap 1
    # verbatim.
    #
    # The honest invariant is a subtraction, not a list: every unit type Woods
    # knows about must be reachable *somehow* — per file, wholesale, or by
    # runtime class discovery. Anything left over is un-indexable.
    # `rails_source` is deliberately outside app-change dispatch: it extracts
    # installed gem sources, which change when the Gemfile.lock does, not when
    # app files do. It is driven by `woods:extract_framework` and is the one
    # extraction mode that does not bump the generation.
    let(:not_app_dispatched) { %i[rails_source] }

    it 'leaves no unit type reachable by no route at all' do
      class_based = Woods::Extractor::CLASS_BASED_DISCOVERY.values.map { |spec| spec[:type] }
      unreachable = Woods::Extractor::TYPE_TO_EXTRACTOR_KEY.except(*class_based)
                                                           .values.to_set - covered_extractor_keys -
                    not_app_dispatched

      expect(unreachable).to(be_empty, "unit types with no dispatch route: #{unreachable.to_a.inspect}")
    end

    def covered_extractor_keys
      described_class.file_rules.to_set(&:extractor_key) +
        described_class.whole_app_rules.to_set(&:extractor_key)
    end

    def uncovered_extractor_keys
      expected = Woods::Extractor::FILE_BASED.keys.to_set do |type|
        Woods::Extractor::TYPE_TO_EXTRACTOR_KEY[type]
      end
      expected - covered_extractor_keys
    end

    # Scenic keeps only the highest _vNN of each view, so a per-file rule
    # would index a superseded version a full extraction drops.
    it 'routes database views wholesale rather than per file' do
      expect(keys_for('db/views/reports_v02.sql')).to be_empty
      expect(dispatcher.whole_app_keys_for('db/views/reports_v02.sql')).to include(:database_views)
    end
  end

  describe '#whole_app_keys_for' do
    it 'triggers a routes re-run on config/routes.rb' do
      expect(dispatcher.whole_app_keys_for('config/routes.rb')).to include(:routes)
    end

    it 'triggers a routes re-run on a drawn route file' do
      expect(dispatcher.whole_app_keys_for('config/routes/admin.rb')).to include(:routes)
    end

    it 'triggers a middleware re-run on an initializer' do
      expect(dispatcher.whole_app_keys_for('config/initializers/rack.rb')).to include(:middleware)
    end

    it 'triggers a scheduled-job re-run on each known schedule file' do
      Woods::Extractors::ScheduledJobExtractor::SCHEDULE_FILES.each_key do |path|
        expect(dispatcher.whole_app_keys_for(path)).to include(:scheduled_jobs)
      end
    end

    it 'triggers state-machine and event re-runs on a model change' do
      expect(dispatcher.whole_app_keys_for('app/models/post.rb')).to include(:state_machines, :events)
    end

    it 'triggers a factory re-run on a factory file' do
      expect(dispatcher.whole_app_keys_for('spec/factories/posts.rb')).to include(:factories)
    end

    it 'triggers nothing for an unrelated path' do
      expect(dispatcher.whole_app_keys_for('README.md')).to be_empty
    end

    it 'unions the triggers across a whole change set' do
      keys = dispatcher.whole_app_keys_for_all(['config/routes.rb', 'app/models/post.rb'])

      expect(keys).to include(:routes, :state_machines, :events)
    end

    it 'names a unit type for every whole-app rule' do
      described_class.whole_app_rules.each do |rule|
        expect(Woods::Extractor::WHOLE_APP_EXTRACTORS).to have_key(rule.extractor_key)
      end
    end
  end

  # The `woods:incremental` rake task filters a raw git diff through this
  # before handing it to extract_changed. A path dropped here never reaches
  # the index however good the dispatch behind it is.
  describe '#relevant?' do
    it 'accepts paths a file rule claims' do
      expect(dispatcher).to be_relevant('app/services/checkout.rb')
      expect(dispatcher).to be_relevant('config/locales/en.yml')
      expect(dispatcher).to be_relevant('lib/tasks/export.rake')
      expect(dispatcher).to be_relevant('spec/models/post_spec.rb')
    end

    it 'accepts paths that only trigger a whole-app re-run' do
      expect(dispatcher).to be_relevant('config/routes.rb')
      expect(dispatcher).to be_relevant('Gemfile.lock')
      expect(dispatcher).to be_relevant('db/views/reports_v01.sql')
      expect(dispatcher).to be_relevant('spec/factories/posts.rb')
    end

    it 'accepts any Ruby file under app/, since class-based types are found by descendants' do
      expect(dispatcher).to be_relevant('app/channels/chat_channel.rb')
      expect(dispatcher).to be_relevant('app/mailers/user_mailer.rb')
    end

    it 'rejects paths no extractor cares about' do
      expect(dispatcher).not_to be_relevant('README.md')
      expect(dispatcher).not_to be_relevant('app/assets/stylesheets/application.css')
      expect(dispatcher).not_to be_relevant('.github/workflows/ci.yml')
    end
  end
end
