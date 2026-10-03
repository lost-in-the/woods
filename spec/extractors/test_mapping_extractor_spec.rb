# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'woods/model_name_cache'
require 'woods/extractors/test_mapping_extractor'

RSpec.describe Woods::Extractors::TestMappingExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing spec/ and test/ directories gracefully' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers *_spec.rb files in spec/' do
      create_file('spec/models/user_spec.rb', <<~RUBY)
        describe User do
          it 'is valid' do
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:test_mapping)
    end

    it 'discovers *_test.rb files in test/' do
      create_file('test/models/user_test.rb', <<~RUBY)
        class UserTest < ActiveSupport::TestCase
          test "is valid" do
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:test_mapping)
    end

    it 'collects units from both spec/ and test/ directories' do
      create_file('spec/models/user_spec.rb', <<~RUBY)
        describe User do
        end
      RUBY

      create_file('test/models/post_test.rb', <<~RUBY)
        class PostTest < ActiveSupport::TestCase
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
    end

    it 'collects units from multiple spec files' do
      create_file('spec/models/user_spec.rb', 'describe User do; end')
      create_file('spec/models/post_spec.rb', 'describe Post do; end')

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
    end
  end

  # ── extract_test_file ────────────────────────────────────────────────

  describe '#extract_test_file' do
    context 'with RSpec files' do
      it 'uses relative path as identifier' do
        path = create_file('spec/models/user_spec.rb', <<~RUBY)
          describe User do
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.identifier).to eq('spec/models/user_spec.rb')
      end

      it 'sets type to :test_mapping' do
        path = create_file('spec/models/user_spec.rb', 'describe User do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.type).to eq(:test_mapping)
      end

      it 'detects subject class from constant describe' do
        path = create_file('spec/models/user_spec.rb', <<~RUBY)
          describe User do
            it 'does something' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('User')
      end

      it 'detects subject class from string describe' do
        path = create_file('spec/models/user_spec.rb', <<~RUBY)
          describe 'User' do
            it 'does something' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('User')
      end

      it 'detects subject class from RSpec.describe form' do
        path = create_file('spec/models/user_spec.rb', <<~RUBY)
          RSpec.describe User do
            it 'does something' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('User')
      end

      # Regression: B-082 / #194 — the rspec-rails generator default
      # `RSpec.describe User, type: :model do` has a comma after the constant.
      # The old constant regex required whitespace, so the string fallback
      # grabbed the first quoted describe anywhere (an inner 'validations')
      # and minted a phantom graph node in place of the real coverage edge.
      it 'detects subject class from generator-default describe with type metadata' do
        path = create_file('spec/models/user_spec.rb', <<~RUBY)
          RSpec.describe User, type: :model do
            describe 'validations' do
              it 'requires a name' do; end
            end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('User')
      end

      it 'links the type-metadata describe to the model, never the inner string describe' do
        path = create_file('spec/models/user_spec.rb', <<~RUBY)
          RSpec.describe User, type: :model do
            describe 'validations' do
              it 'requires a name' do; end
            end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.dependencies).to eq([{ type: :model, target: 'User', via: :test_coverage }])
        targets = unit.dependencies.map { |dep| dep[:target] }
        expect(targets).not_to include('validations')
      end

      it 'qualifies a constant described inside a module block by its lexical nesting' do
        path = create_file('spec/services/nested/assign_positions_spec.rb', <<~RUBY)
          module Nested
            describe AssignPositions do
              it 'assigns' do; end
            end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('Nested::AssignPositions')
        expect(unit.dependencies).to eq([{ type: :model, target: 'Nested::AssignPositions', via: :test_coverage }])
      end

      it 'qualifies through several nested modules and a compact module name' do
        path = create_file('spec/services/x_spec.rb', <<~RUBY)
          module Billing::Ledger
            module Jobs
              RSpec.describe RebuildJob, type: :job do
              end
            end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('Billing::Ledger::Jobs::RebuildJob')
        expect(unit.dependencies.first).to include(type: :job, target: 'Billing::Ledger::Jobs::RebuildJob')
      end

      it 'does not qualify a constant described after the module block closed, or one already rooted' do
        after_close = create_file('spec/services/after_spec.rb', <<~RUBY)
          module Helpers
            def self.build; end
          end

          describe AssignPositions do
          end
        RUBY
        rooted = create_file('spec/services/rooted_spec.rb', <<~RUBY)
          module Nested
            describe ::AssignPositions do
            end
          end
        RUBY

        expect(described_class.new.extract_test_file(after_close).metadata[:subject_class]).to eq('AssignPositions')
        expect(described_class.new.extract_test_file(rooted).metadata[:subject_class]).to eq('AssignPositions')
      end

      it 'leaves a quoted subject inside a module block as written' do
        path = create_file('spec/features/nested_spec.rb', <<~RUBY)
          module Nested
            RSpec.feature 'Widget checkout' do
            end
          end
        RUBY

        expect(described_class.new.extract_test_file(path).metadata).to include(description: 'Widget checkout')
      end

      it 'preserves namespaced constants in type-metadata describes' do
        path = create_file('spec/policies/user_policy_spec.rb', <<~RUBY)
          RSpec.describe Admin::UserPolicy, type: :policy do
            it 'permits admins' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('Admin::UserPolicy')
      end

      it 'records a free-text string describe as the description, not the subject class' do
        path = create_file('spec/tasks/cleanup_spec.rb', <<~RUBY)
          RSpec.describe 'rake tasks' do
            it 'runs cleanup' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata).to include(subject_class: nil, description: 'rake tasks')
      end

      it 'emits no coverage edge for a free-text string describe' do
        path = create_file('spec/features/widget_checkout_spec.rb', <<~RUBY)
          RSpec.describe 'Widget checkout', type: :feature do
            it 'shows the form' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.dependencies).to eq([])
      end

      it 'uses the first describe of a request spec even with type metadata after the string' do
        path = create_file('spec/requests/users_spec.rb', <<~RUBY)
          RSpec.describe 'GET /users', type: :request do
            describe 'authentication' do
              it 'requires login' do; end
            end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata).to include(subject_class: nil, description: 'GET /users')
      end

      it 'links a namespaced constant-path string describe like a constant describe' do
        path = create_file('spec/models/ledger/entry_spec.rb', <<~RUBY)
          RSpec.describe 'Ledger::Entry' do
            it 'balances' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('Ledger::Entry')
        expect(unit.dependencies).to eq([{ type: :model, target: 'Ledger::Entry', via: :test_coverage }])
      end

      it 'adds no description key for a constant describe' do
        path = create_file('spec/models/widget_spec.rb', 'RSpec.describe Widget, type: :model do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata).not_to have_key(:description)
      end

      it 'records an RSpec.feature block as the description' do
        path = create_file('spec/features/widget_checkout_spec.rb', <<~RUBY)
          RSpec.feature 'Widget checkout' do
            scenario 'with a saved card' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata).to include(subject_class: nil, description: 'Widget checkout')
        expect(unit.dependencies).to eq([])
      end

      it 'records a bare feature block as the description' do
        path = create_file('spec/features/widget_checkout_spec.rb', <<~RUBY)
          feature "Widget checkout" do
            scenario 'with a saved card' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:description]).to eq('Widget checkout')
      end

      it 'keeps the feature block as the subject when an inner describe names a constant' do
        path = create_file('spec/features/widget_checkout_spec.rb', <<~RUBY)
          RSpec.feature 'Widget checkout' do
            describe Widget do
              scenario 'with a saved card' do; end
            end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata).to include(subject_class: nil, description: 'Widget checkout')
      end

      it 'keeps a namespaced task-name describe under spec/lib/tasks/ as the subject' do
        create_file('lib/tasks/ledger.rake', <<~RUBY)
          namespace :ledger do
            task rebuild_balances: :environment do
            end
          end
        RUBY
        path = create_file('spec/lib/tasks/ledger/rebuild_balances_spec.rb', <<~RUBY)
          RSpec.describe "ledger:rebuild_balances" do
            it 'rebuilds' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('ledger:rebuild_balances')
        expect(unit.metadata).not_to have_key(:description)
        expect(unit.dependencies)
          .to eq([{ type: :rake_task, target: 'ledger:rebuild_balances', via: :test_coverage }])
      end

      it 'links a namespace describe to every task in the namespace' do
        create_file('lib/tasks/ledger.rake', <<~RUBY)
          namespace :ledger do
            task rebuild_balances: :environment do
            end

            namespace :audit do
              task run: :environment do
              end
            end
          end

          task ledger_export: :environment do
          end
        RUBY
        path = create_file('spec/lib/tasks/ledger_spec.rb', <<~RUBY)
          RSpec.describe "ledger" do
            it 'rebuilds' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata).to include(subject_class: nil, description: 'ledger', rake_namespace: 'ledger')
        expect(unit.dependencies).to eq(
          [{ type: :rake_task, target: 'ledger:audit:run', via: :test_coverage },
           { type: :rake_task, target: 'ledger:rebuild_balances', via: :test_coverage }]
        )
      end

      it 'records a task-shaped describe that names no task or namespace as the description' do
        create_file('lib/tasks/ledger.rake', "task ledger_export: :environment do\nend\n")
        path = create_file('spec/lib/tasks/shipments_spec.rb', <<~RUBY)
          RSpec.describe "shipments" do
            it 'ships' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata).to include(subject_class: nil, description: 'shipments')
        expect(unit.metadata).not_to have_key(:rake_namespace)
        expect(unit.dependencies).to eq([])
      end

      it 'keeps a task-name describe under spec/tasks/ as the subject' do
        create_file('lib/tasks/export.rake', "task export_widgets: :environment do\nend\n")
        path = create_file('spec/tasks/export_widgets_spec.rb', <<~RUBY)
          RSpec.describe "export_widgets" do
            it 'exports' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('export_widgets')
        expect(unit.dependencies).to eq([{ type: :rake_task, target: 'export_widgets', via: :test_coverage }])
      end

      it 'records a task-shaped describe outside a tasks directory as the description' do
        path = create_file('spec/lib/widget_exporter_spec.rb', <<~RUBY)
          RSpec.describe "export_widgets" do
            it 'exports' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata).to include(subject_class: nil, description: 'export_widgets')
        expect(unit.dependencies).to eq([])
      end

      it 'records a constant-shaped feature title as the description' do
        path = create_file('spec/features/changelog_spec.rb', <<~RUBY)
          RSpec.feature "Changelog", type: :feature do
            scenario 'lists entries' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata).to include(subject_class: nil, description: 'Changelog')
        expect(unit.dependencies).to eq([])
      end

      it 'links an unquoted constant feature argument like a constant describe' do
        path = create_file('spec/features/widget_spec.rb', <<~RUBY)
          RSpec.feature Widget do
            scenario 'lists widgets' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('Widget')
        expect(unit.dependencies).to eq([{ type: :model, target: 'Widget', via: :test_coverage }])
      end

      it 'counts it blocks as test_count' do
        path = create_file('spec/models/user_spec.rb', <<~RUBY)
          describe User do
            it 'is valid' do; end
            it 'has a name' do; end
            specify 'it does x' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_count]).to eq(3)
      end

      it 'sets test_framework to :rspec' do
        path = create_file('spec/models/user_spec.rb', 'describe User do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_framework]).to eq(:rspec)
      end

      it 'infers :model test_type from spec/models/ path' do
        path = create_file('spec/models/user_spec.rb', 'describe User do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:model)
      end

      it 'infers :controller test_type from spec/controllers/ path' do
        path = create_file('spec/controllers/users_controller_spec.rb',
                           'describe UsersController do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:controller)
      end

      it 'infers :request test_type from spec/requests/ path' do
        path = create_file('spec/requests/users_spec.rb', 'describe "Users API" do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:request)
      end

      it 'infers :system test_type from spec/system/ path' do
        path = create_file('spec/system/login_spec.rb', 'describe "Login" do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:system)
      end

      it 'infers :feature test_type from spec/features/ path' do
        path = create_file('spec/features/widget_checkout_spec.rb', 'describe "Widget checkout" do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:feature)
      end

      it 'infers :feature test_type from type: :feature metadata outside spec/features/' do
        path = create_file('spec/acceptance/widget_checkout_spec.rb', <<~RUBY)
          RSpec.describe 'Widget checkout', type: :feature do
            it 'shows the form' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:feature)
      end

      it 'infers :system test_type from type: :system metadata outside spec/system/' do
        path = create_file('spec/acceptance/widget_checkout_spec.rb', <<~RUBY)
          RSpec.describe "Widget checkout", type: :system do
            it 'shows the form' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:system)
      end

      it 'infers :feature test_type from a feature block outside spec/features/' do
        path = create_file('spec/acceptance/widget_checkout_spec.rb', <<~RUBY)
          RSpec.feature 'Widget checkout' do
            scenario 'with a saved card' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:feature)
      end

      it 'keeps the directory test_type when the describe declares a different type' do
        path = create_file('spec/requests/widgets_spec.rb', <<~RUBY)
          RSpec.describe 'Widgets', type: :feature do
            it 'lists widgets' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:request)
      end

      it 'reads type metadata from the first example group only' do
        path = create_file('spec/lib/widget_formatter_spec.rb', <<~RUBY)
          RSpec.describe WidgetFormatter do
            describe 'rendering', type: :system do
              it 'formats' do; end
            end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:unit)
      end

      it 'defaults to :unit test_type for unrecognized paths' do
        path = create_file('spec/support/helpers_spec.rb', 'describe "Helpers" do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:unit)
      end

      it 'detects shared_examples defined in the file' do
        path = create_file('spec/shared/user_spec.rb', <<~RUBY)
          shared_examples 'a valid user' do
            it 'is valid' do; end
          end

          shared_examples_for 'an admin' do
            it 'has admin role' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:shared_examples]).to contain_exactly('a valid user', 'an admin')
      end

      it 'detects shared_examples used in the file' do
        path = create_file('spec/models/user_spec.rb', <<~RUBY)
          describe User do
            it_behaves_like 'a valid user'
            include_examples 'an admin'
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:shared_examples_used]).to contain_exactly('a valid user', 'an admin')
      end

      it 'links to model via :test_coverage dependency for model subject' do
        path = create_file('spec/models/user_spec.rb', 'describe User do; end')

        unit = described_class.new.extract_test_file(path)
        dep = unit.dependencies.first
        expect(dep[:type]).to eq(:model)
        expect(dep[:target]).to eq('User')
        expect(dep[:via]).to eq(:test_coverage)
      end

      it 'links to controller via :test_coverage dependency for controller subject' do
        path = create_file('spec/controllers/users_controller_spec.rb',
                           'describe UsersController do; end')

        unit = described_class.new.extract_test_file(path)
        dep = unit.dependencies.first
        expect(dep[:type]).to eq(:controller)
        expect(dep[:target]).to eq('UsersController')
        expect(dep[:via]).to eq(:test_coverage)
      end

      it 'links to job via :test_coverage dependency for job subject' do
        path = create_file('spec/jobs/process_order_job_spec.rb',
                           'describe ProcessOrderJob do; end')

        unit = described_class.new.extract_test_file(path)
        dep = unit.dependencies.first
        expect(dep[:type]).to eq(:job)
        expect(dep[:target]).to eq('ProcessOrderJob')
      end

      it 'links to mailer via :test_coverage dependency for mailer subject' do
        path = create_file('spec/mailers/user_mailer_spec.rb',
                           'describe UserMailer do; end')

        unit = described_class.new.extract_test_file(path)
        dep = unit.dependencies.first
        expect(dep[:type]).to eq(:mailer)
        expect(dep[:target]).to eq('UserMailer')
      end

      it 'links to service via :test_coverage dependency for service subject' do
        path = create_file('spec/services/checkout_service_spec.rb',
                           'describe CheckoutService do; end')

        unit = described_class.new.extract_test_file(path)
        dep = unit.dependencies.first
        expect(dep[:type]).to eq(:service)
        expect(dep[:target]).to eq('CheckoutService')
      end

      it 'returns empty dependencies when subject_class is nil' do
        path = create_file('spec/support/shared_examples.rb', <<~RUBY)
          shared_examples 'a valid model' do
            it 'is valid' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.dependencies).to eq([])
      end
    end

    context 'with Minitest files' do
      it 'uses relative path as identifier' do
        path = create_file('test/models/user_test.rb', <<~RUBY)
          class UserTest < ActiveSupport::TestCase
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.identifier).to eq('test/models/user_test.rb')
      end

      it 'detects subject class by stripping Test suffix' do
        path = create_file('test/models/user_test.rb', <<~RUBY)
          class UserTest < ActiveSupport::TestCase
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('User')
      end

      it 'counts test "..." blocks and def test_ methods' do
        path = create_file('test/models/user_test.rb', <<~RUBY)
          class UserTest < ActiveSupport::TestCase
            test "is valid" do
            end

            test "has a name" do
            end

            def test_it_saves
            end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_count]).to eq(3)
      end

      it 'sets test_framework to :minitest' do
        path = create_file('test/models/user_test.rb', <<~RUBY)
          class UserTest < ActiveSupport::TestCase
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_framework]).to eq(:minitest)
      end

      it 'infers :model test_type from test/models/ path' do
        path = create_file('test/models/user_test.rb', 'class UserTest < ActiveSupport::TestCase; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:model)
      end

      it 'links to model via :test_coverage dependency' do
        path = create_file('test/models/user_test.rb', <<~RUBY)
          class UserTest < ActiveSupport::TestCase
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        dep = unit.dependencies.first
        expect(dep[:type]).to eq(:model)
        expect(dep[:target]).to eq('User')
        expect(dep[:via]).to eq(:test_coverage)
      end
    end

    it 'sets source_code to the file contents' do
      path = create_file('spec/models/user_spec.rb', <<~RUBY)
        describe User do
          it 'is valid' do; end
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      expect(unit.source_code).to include('describe User do')
    end

    it 'sets file_path on the unit' do
      path = create_file('spec/models/user_spec.rb', 'describe User do; end')

      unit = described_class.new.extract_test_file(path)
      expect(unit.file_path).to eq(path)
    end

    it 'includes dependency with :via key' do
      path = create_file('spec/models/user_spec.rb', 'describe User do; end')

      unit = described_class.new.extract_test_file(path)
      unit.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end

    it 'handles read errors gracefully' do
      unit = described_class.new.extract_test_file('/nonexistent/path_spec.rb')
      expect(unit).to be_nil
    end
  end

  # ── Metadata ─────────────────────────────────────────────────────────

  describe 'metadata' do
    it 'includes all expected keys' do
      path = create_file('spec/models/user_spec.rb', <<~RUBY)
        describe User do
          it 'is valid' do; end
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      meta = unit.metadata

      expect(meta).to have_key(:subject_class)
      expect(meta).to have_key(:test_count)
      expect(meta).to have_key(:test_type)
      expect(meta).to have_key(:test_framework)
      expect(meta).to have_key(:shared_examples)
      expect(meta).to have_key(:shared_examples_used)
    end

    it 'returns nil subject_class when describe target is not detectable' do
      path = create_file('spec/support/misc_spec.rb', <<~RUBY)
        RSpec.configure do |config|
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      expect(unit.metadata[:subject_class]).to be_nil
    end
  end

  # ── Test support references ─────────────────────────────────────────

  describe 'test support references' do
    before do
      create_file('spec/support/shared/pages.rb', <<~RUBY)
        RSpec.shared_examples "an accessible page" do |exclusions: []|
        end
        RSpec.shared_examples 'a paginated list' do
        end
      RUBY
      create_file('spec/support/billing_stubs.rb', "RSpec.shared_context 'with billing stubs' do\nend\n")
      create_file('spec/support/matchers/combobox.rb', "RSpec::Matchers.define :have_combobox do |label|\nend\n")
      create_file('spec/support/analytics_helpers.rb',
                  "module AnalyticsHelpers\n  def expect_tracked(name) = true\nend\n")
    end

    def support_edges(unit)
      unit.dependencies.select { |dep| dep[:type] == :test_support }
    end

    it 'links every shared example form to the file that defines the examples' do
      path = create_file('spec/features/widgets_spec.rb', <<~RUBY)
        RSpec.feature 'Widgets' do
          it_behaves_like "an accessible page"
          include_examples 'a paginated list'
          it_should_behave_like 'an accessible page', exclusions: [:contrast]
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      expect(support_edges(unit)).to eq(
        [{ type: :test_support, target: 'spec/support/shared/pages.rb', via: :behaves_like }]
      )
      expect(unit.metadata[:shared_examples_used]).to eq(['an accessible page', 'a paginated list'])
    end

    it 'links include_context to the shared context file' do
      path = create_file('spec/requests/invoices_spec.rb', <<~RUBY)
        RSpec.describe 'Invoices', type: :request do
          include_context 'with billing stubs'
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      expect(support_edges(unit)).to eq(
        [{ type: :test_support, target: 'spec/support/billing_stubs.rb', via: :includes_context }]
      )
      expect(unit.metadata[:shared_contexts_used]).to eq(['with billing stubs'])
    end

    it 'links a custom matcher call to the matcher file' do
      path = create_file('spec/features/plans_spec.rb', <<~RUBY)
        RSpec.feature 'Plans' do
          scenario 'choosing a plan' do
            expect(page).to have_combobox('Plan')
            expect(page).not_to have_combobox_placeholder
          end
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      expect(support_edges(unit)).to eq(
        [{ type: :test_support, target: 'spec/support/matchers/combobox.rb', via: :uses_matcher }]
      )
      expect(unit.metadata[:matchers_used]).to eq(['have_combobox'])
    end

    it 'does not read a longer method name as a matcher call' do
      path = create_file('spec/features/plans_spec.rb', <<~RUBY)
        RSpec.feature 'Plans' do
          scenario('x') { expect(page).to have_combobox_placeholder; page.have_combobox }
        end
      RUBY

      expect(support_edges(described_class.new.extract_test_file(path))).to eq([])
    end

    it 'links an included helper module to its file' do
      path = create_file('spec/services/tracker_spec.rb', <<~RUBY)
        RSpec.describe Tracker do
          include AnalyticsHelpers
          include ActiveSupport::Testing::TimeHelpers
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      expect(unit.dependencies).to eq(
        [{ type: :model, target: 'Tracker', via: :test_coverage },
         { type: :test_support, target: 'spec/support/analytics_helpers.rb', via: :includes_helper }]
      )
      expect(unit.metadata[:helpers_included]).to eq(%w[AnalyticsHelpers ActiveSupport::Testing::TimeHelpers])
    end

    it 'emits no edge for a name no support file defines' do
      path = create_file('spec/models/widget_spec.rb', <<~RUBY)
        RSpec.describe Widget do
          it_behaves_like 'a ghost'
          include_context 'nowhere'
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      expect(support_edges(unit)).to eq([])
      expect(unit.metadata).to include(shared_examples_used: ['a ghost'], shared_contexts_used: ['nowhere'])
    end

    it 'orders edges the same way whatever order the references appear in' do
      body = ["  include AnalyticsHelpers\n", "  include_context 'with billing stubs'\n",
              "  it_behaves_like 'an accessible page'\n", "  it { is_expected.to have_combobox('x') }\n"]
      edges = [body, body.reverse].map do |lines|
        path = create_file('spec/features/order_spec.rb', "RSpec.feature 'Order' do\n#{lines.join}end\n")
        support_edges(described_class.new.extract_test_file(path))
      end

      expect(edges.first).to eq(edges.last)
      expect(edges.first.map { |dep| dep[:via] })
        .to eq(%i[behaves_like includes_context includes_helper uses_matcher])
    end
  end

  describe 'test_count' do
    it 'counts Capybara scenarios' do
      path = create_file('spec/features/widgets_spec.rb', <<~RUBY)
        RSpec.feature 'Widgets' do
          scenario 'listing' do; end
          scenario "creating" do; end
          it 'renders' do; end
        end
      RUBY

      expect(described_class.new.extract_test_file(path).metadata[:test_count]).to eq(3)
    end
  end

  # ── Routes exercised ────────────────────────────────────────────────

  describe 'routes exercised' do
    before do
      stub_route_set(
        [route_double(verb: 'GET', path: '/widgets', controller: 'widgets', action: 'index', name: 'widgets'),
         route_double(verb: 'POST', path: '/widgets', controller: 'widgets', action: 'create'),
         route_double(verb: 'GET', path: '/widgets/:id', controller: 'widgets', action: 'show', name: 'widget')],
        root: rails_root, logger: logger
      )
    end

    def route_edges(unit)
      unit.dependencies.select { |dep| dep[:via] == :exercises_route }
    end

    it 'links a feature spec to the routes it visits' do
      path = create_file('spec/features/widgets_spec.rb', <<~RUBY)
        RSpec.feature 'Widgets' do
          scenario 'browsing' do
            visit widgets_path
            visit "/widgets/\#{widget.id}"
          end
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      expect(route_edges(unit)).to eq(
        [{ type: :route, target: 'GET /widgets', via: :exercises_route },
         { type: :route, target: 'GET /widgets/:id', via: :exercises_route }]
      )
      expect(unit.metadata[:routes_exercised]).to eq(['GET /widgets', 'GET /widgets/:id'])
    end

    it 'records asserted and ambiguous routes in metadata without edges' do
      stub_route_set(
        [route_double(verb: 'GET', path: '/widgets', controller: 'widgets', action: 'index', name: 'widgets'),
         route_double(verb: 'GET', path: '/:id', controller: 'shops', action: 'show',
                      constraints: { subdomain: 'shop' }),
         route_double(verb: 'GET', path: '/:slug', controller: 'pages', action: 'show')],
        root: rails_root, logger: logger
      )
      path = create_file('spec/features/pages_spec.rb', <<~RUBY)
        RSpec.feature 'Pages' do
          scenario 'browsing' do
            visit "/pricing"
            expect(page).to have_current_path(widgets_path)
          end
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      expect(route_edges(unit)).to eq([])
      expect(unit.metadata).to include(
        routes_exercised: [],
        routes_asserted: ['GET /widgets'],
        routes_ambiguous: [{ request: 'GET /pricing', candidates: ['GET /:id [subdomain=shop]', 'GET /:slug'] }]
      )
    end

    it 'links a request spec by verb' do
      path = create_file('spec/requests/widgets_spec.rb', <<~RUBY)
        RSpec.describe 'Widgets API' do
          it 'creates' do
            post widgets_path, params: {}
          end
        end
      RUBY

      expect(route_edges(described_class.new.extract_test_file(path)).map { |dep| dep[:target] })
        .to eq(['POST /widgets'])
    end

    it 'links system specs and Minitest integration and system tests' do
      spec = create_file('spec/system/widgets_spec.rb',
                         "RSpec.describe 'Widgets' do\n  it('x') { visit widgets_path }\nend\n")
      integration = create_file('test/integration/widgets_test.rb', <<~RUBY)
        class WidgetsTest < ActionDispatch::IntegrationTest
          test "index" do
            get widgets_url
          end
        end
      RUBY

      [spec, integration].each do |file|
        expect(route_edges(described_class.new.extract_test_file(file)).map { |dep| dep[:target] })
          .to eq(['GET /widgets'])
      end
    end

    it 'honors a request type declared on the first example group' do
      path = create_file('spec/api/widgets_spec.rb', <<~RUBY)
        RSpec.describe 'Widgets API', type: :request do
          it('lists') { get "/widgets" }
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      expect(unit.metadata[:test_type]).to eq(:request)
      expect(unit.metadata[:routes_exercised]).to eq(['GET /widgets'])
    end

    it 'does not scan other test types' do
      path = create_file('spec/controllers/widgets_controller_spec.rb', <<~RUBY)
        RSpec.describe WidgetsController do
          it('lists') { get "/widgets" }
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      expect(route_edges(unit)).to eq([])
      expect(unit.metadata[:routes_exercised]).to eq([])
    end
  end

  # ── Serialization round-trip ────────────────────────────────────────

  describe 'serialization' do
    it 'to_h round-trips correctly' do
      path = create_file('spec/models/user_spec.rb', <<~RUBY)
        describe User do
          it 'is valid' do; end
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      hash = unit.to_h

      expect(hash[:type]).to eq(:test_mapping)
      expect(hash[:identifier]).to eq('spec/models/user_spec.rb')
      expect(hash[:source_hash]).to be_a(String)
      expect(hash[:extracted_at]).to be_a(String)

      json = JSON.generate(hash)
      parsed = JSON.parse(json)
      expect(parsed['type']).to eq('test_mapping')
      expect(parsed['identifier']).to eq('spec/models/user_spec.rb')
    end
  end
end
