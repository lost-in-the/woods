# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extractors/test_support_extractor'

RSpec.describe Woods::Extractors::TestSupportExtractor do
  include_context 'extractor setup'

  around do |example|
    original = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    example.run
  ensure
    Woods.configuration = original
  end

  def units
    described_class.new.extract_all
  end

  def unit_for(identifier)
    units.find { |unit| unit.identifier == identifier }
  end

  it 'returns nothing when the app has no test support files' do
    expect(units).to eq([])
  end

  it 'keeps the catalog defaults in step with the configuration default' do
    expect(Woods::Extractors::TestSupportCatalog::DEFAULT_PATHS).to eq(Woods::Configuration.new.test_support_paths)
  end

  describe 'discovery' do
    it 'indexes support directories, root helpers, and spec/lib support files' do
      create_file('spec/support/analytics_helpers.rb', "module AnalyticsHelpers\nend\n")
      create_file('spec/support/shared/nested/accessible.rb', "RSpec.shared_examples 'an accessible page' do\nend\n")
      create_file('spec/rails_helper.rb', "RSpec.configure do |config|\nend\n")
      create_file('spec/lib/ledger_fixtures.rb', "module LedgerFixtures\nend\n")
      create_file('test/support/sign_in.rb', "module SignIn\nend\n")
      create_file('test/test_helper.rb', "class ActiveSupport::TestCase\nend\n")

      expect(units.map(&:identifier)).to eq(
        %w[spec/lib/ledger_fixtures.rb spec/rails_helper.rb spec/support/analytics_helpers.rb
           spec/support/shared/nested/accessible.rb test/support/sign_in.rb test/test_helper.rb]
      )
      expect(units.map(&:type).uniq).to eq([:test_support])
    end

    it 'never indexes a test file, even under a support glob' do
      create_file('spec/lib/ledger_spec.rb', "RSpec.describe Ledger do\nend\n")
      create_file('spec/support/widget_helper_spec.rb', "RSpec.describe WidgetHelper do\nend\n")
      create_file('test/lib/ledger_test.rb', "class LedgerTest < Minitest::Test\nend\n")

      expect(units).to eq([])
    end

    it 'indexes a fixture class in a spec/lib subdirectory even when its name ends in _test.rb' do
      create_file('spec/lib/translators/settings_translators/spec_test.rb', <<~RUBY)
        module SettingsTranslators
          class SpecTest
            def translate = nil
          end
        end
      RUBY

      unit = unit_for('spec/lib/translators/settings_translators/spec_test.rb')
      expect(unit.metadata).to include(kind: 'class', classes: ['SettingsTranslators::SpecTest'])
    end

    it 'ignores Ruby outside the configured globs' do
      create_file('spec/models/widget_spec.rb', "RSpec.describe Widget do\nend\n")
      create_file('spec/fixtures/sample.rb', "module Sample\nend\n")

      expect(units).to eq([])
    end

    it 'follows config.test_support_paths' do
      Woods.configuration.test_support_paths = ['features/support/**/*.rb']
      create_file('features/support/env.rb', "module FeatureEnv\nend\n")
      create_file('spec/support/analytics_helpers.rb', "module AnalyticsHelpers\nend\n")

      expect(units.map(&:identifier)).to eq(['features/support/env.rb'])
    end

    it 'never reads a symlink that resolves outside the application root' do
      outside = Dir.mktmpdir
      File.write(File.join(outside, 'secrets.rb'), "module OutsideSecrets\nend\n")
      FileUtils.mkdir_p(File.join(tmp_dir, 'spec/support'))
      FileUtils.mkdir_p(File.join(tmp_dir, 'spec/factories'))
      File.symlink(File.join(outside, 'secrets.rb'), File.join(tmp_dir, 'spec/support/linked.rb'))
      File.symlink(File.join(outside, 'secrets.rb'), File.join(tmp_dir, 'spec/factories/linked.rb'))
      File.symlink(outside, File.join(tmp_dir, 'spec/support/linked_dir'))
      create_file('spec/support/real.rb', "module Real\nend\n")
      File.symlink(File.join(tmp_dir, 'spec/support/real.rb'), File.join(tmp_dir, 'spec/support/alias.rb'))

      expect(units.map(&:identifier)).to eq(%w[spec/support/alias.rb spec/support/real.rb])
    ensure
      FileUtils.rm_rf(outside) if outside
    end

    it 'sets the file path and the whole file as source' do
      path = create_file('spec/support/analytics_helpers.rb', "module AnalyticsHelpers\nend\n")

      unit = unit_for('spec/support/analytics_helpers.rb')
      expect(unit.file_path).to eq(path)
      expect(unit.source_code).to eq("module AnalyticsHelpers\nend\n")
    end
  end

  describe 'kinds and names' do
    it 'describes a helper module with its methods' do
      create_file('spec/support/analytics_helpers.rb', <<~RUBY)
        module AnalyticsHelpers
          def expect_tracked(account, name, **props) = true

          def self.reset!
          end
        end
      RUBY

      expect(unit_for('spec/support/analytics_helpers.rb').metadata).to include(
        kind: 'helper_module', kinds: ['helper_module'], helper_modules: ['AnalyticsHelpers'],
        methods: %w[expect_tracked reset!], names: ['AnalyticsHelpers'], test_framework: 'rspec'
      )
    end

    it 'qualifies nested helper modules' do
      create_file('spec/support/billing.rb', <<~RUBY)
        module Support
          module BillingHelpers
          end
        end
      RUBY

      expect(unit_for('spec/support/billing.rb').metadata[:helper_modules])
        .to eq(%w[Support Support::BillingHelpers])
    end

    it 'describes shared examples in every declaration form' do
      create_file('spec/support/shared/pages.rb', <<~RUBY)
        RSpec.shared_examples "an accessible page" do |exclusions: []|
        end
        shared_examples_for 'a paginated list' do
        end
        RSpec.shared_examples :sortable do
        end
        shared_examples("a user's dashboard") do
        end
      RUBY

      expect(unit_for('spec/support/shared/pages.rb').metadata).to include(
        kind: 'shared_examples',
        shared_examples: ['an accessible page', 'a paginated list', 'sortable', "a user's dashboard"]
      )
    end

    it 'describes shared contexts' do
      create_file('spec/support/billing_stubs.rb', "RSpec.shared_context 'with billing stubs' do\nend\n")

      expect(unit_for('spec/support/billing_stubs.rb').metadata)
        .to include(kind: 'shared_context', shared_contexts: ['with billing stubs'])
    end

    it 'describes custom, negated, and aliased matchers' do
      create_file('spec/support/matchers.rb', <<~RUBY)
        RSpec::Matchers.define :have_combobox do |label|
        end
        RSpec::Matchers.define_negated_matcher :not_have_combobox, :have_combobox
        RSpec::Matchers.alias_matcher :have_picker, :have_combobox
      RUBY

      expect(unit_for('spec/support/matchers.rb').metadata)
        .to include(kind: 'matcher', matchers: %w[have_combobox not_have_combobox have_picker])
    end

    it 'describes a configure-only file with what it includes' do
      create_file('spec/support/config.rb', <<~RUBY)
        RSpec.configure do |c|
          c.include AnalyticsHelpers, type: :feature
          c.include Support::BillingHelpers, type: %i[request system]
          c.extend ClassMacros
          c.include SignIn, :type => :controller
        end
      RUBY

      expect(unit_for('spec/support/config.rb').metadata).to include(
        kind: 'configuration',
        includes: [
          { module: 'AnalyticsHelpers', scope: 'include', types: ['feature'] },
          { module: 'Support::BillingHelpers', scope: 'include', types: %w[request system] },
          { module: 'ClassMacros', scope: 'extend', types: [] },
          { module: 'SignIn', scope: 'include', types: ['controller'] }
        ]
      )
    end

    it 'describes a class file' do
      create_file('spec/support/stripe_mocks.rb', "class StripeMocks < Hash\nend\n")

      expect(unit_for('spec/support/stripe_mocks.rb').metadata)
        .to include(kind: 'class', classes: ['StripeMocks'], names: ['StripeMocks'])
    end

    it 'describes a file that defines nothing as a script' do
      create_file('spec/support/boot.rb', "Capybara.default_max_wait_time = 5\n")

      expect(unit_for('spec/support/boot.rb').metadata).to include(kind: 'script', kinds: ['script'], names: [])
    end

    it 'lists every kind a mixed file has, the most specific first' do
      create_file('spec/support/mixed.rb', <<~RUBY)
        module ComboboxHelpers
        end
        RSpec::Matchers.define :have_combobox do |label|
        end
        RSpec.configure { |c| c.include ComboboxHelpers }
      RUBY

      expect(unit_for('spec/support/mixed.rb').metadata)
        .to include(kind: 'matcher', kinds: %w[matcher helper_module configuration])
    end

    it 'ignores declarations in comments' do
      create_file('spec/support/commented.rb', <<~RUBY)
        # RSpec.shared_examples 'a ghost' do
        # module Ghost
        Capybara.javascript_driver = :headless
      RUBY

      expect(unit_for('spec/support/commented.rb').metadata).to include(kind: 'script', names: [])
    end

    it 'marks Minitest support by its root' do
      create_file('test/support/sign_in.rb', "module SignIn\nend\n")

      expect(unit_for('test/support/sign_in.rb').metadata[:test_framework]).to eq('minitest')
    end
  end

  describe 'included_for' do
    it 'collects the types a helper module is included for across files' do
      create_file('spec/support/analytics_helpers.rb', "module AnalyticsHelpers\nend\n")
      create_file('spec/support/config.rb', "RSpec.configure { |c| c.include AnalyticsHelpers, type: :system }\n")
      create_file('spec/rails_helper.rb', "RSpec.configure do |c|\n  c.include AnalyticsHelpers, type: :feature\nend\n")

      expect(unit_for('spec/support/analytics_helpers.rb').metadata[:included_for]).to eq(%w[feature system])
    end

    it 'reports all when any include is untyped' do
      create_file('spec/support/analytics_helpers.rb', <<~RUBY)
        module AnalyticsHelpers
        end
        RSpec.configure do |config|
          config.include AnalyticsHelpers
          config.include AnalyticsHelpers, type: :feature
        end
      RUBY

      expect(unit_for('spec/support/analytics_helpers.rb').metadata[:included_for]).to eq(['all'])
    end

    it 'matches a namespaced module included by its full name' do
      create_file('spec/support/billing.rb', "module Support\n  module BillingHelpers\n  end\nend\n")
      create_file('spec/rails_helper.rb', "RSpec.configure { |c| c.include Support::BillingHelpers, type: :request }\n")

      expect(unit_for('spec/support/billing.rb').metadata[:included_for]).to eq(['request'])
    end

    it 'is empty for a module nothing includes' do
      create_file('spec/support/analytics_helpers.rb', "module AnalyticsHelpers\nend\n")

      expect(unit_for('spec/support/analytics_helpers.rb').metadata[:included_for]).to eq([])
    end
  end

  describe 'dependencies' do
    it 'links a configuration file to the helper modules it includes' do
      create_file('spec/support/analytics_helpers.rb', "module AnalyticsHelpers\nend\n")
      create_file('spec/rails_helper.rb', "RSpec.configure { |c| c.include AnalyticsHelpers, type: :feature }\n")

      expect(unit_for('spec/rails_helper.rb').dependencies).to eq(
        [{ type: :test_support, target: 'spec/support/analytics_helpers.rb', via: :includes_helper }]
      )
    end

    it 'links shared examples to the shared context and matcher they use' do
      create_file('spec/support/billing_stubs.rb', "RSpec.shared_context 'with billing stubs' do\nend\n")
      create_file('spec/support/matchers.rb', "RSpec::Matchers.define :have_combobox do |label|\nend\n")
      create_file('spec/support/pages.rb', <<~RUBY)
        RSpec.shared_examples 'a billing page' do
          include_context 'with billing stubs'
          it { is_expected.to have_combobox('Plan') }
        end
      RUBY

      expect(unit_for('spec/support/pages.rb').dependencies).to eq(
        [{ type: :test_support, target: 'spec/support/billing_stubs.rb', via: :includes_context },
         { type: :test_support, target: 'spec/support/matchers.rb', via: :uses_matcher }]
      )
    end

    it 'never links a file to itself or to a module no support file defines' do
      create_file('spec/support/analytics_helpers.rb', <<~RUBY)
        module AnalyticsHelpers
        end
        RSpec.configure do |c|
          c.include AnalyticsHelpers
          c.include FactoryBot::Syntax::Methods
        end
      RUBY

      expect(unit_for('spec/support/analytics_helpers.rb').dependencies).to eq([])
    end
  end

  describe 'factory directories' do
    it 'indexes a definition file that declares no factory' do
      create_file('spec/factories/callbacks.rb', <<~RUBY)
        FactoryBot.define do
          after(:build) { |record| record.touch }
        end
      RUBY

      unit = unit_for('spec/factories/callbacks.rb')
      expect(unit.metadata).to include(kind: 'configuration', kinds: ['configuration'])
    end

    it 'leaves a file that declares a factory to the factory extractor' do
      create_file('spec/factories/widgets.rb', "FactoryBot.define do\n  factory :widget do\n  end\nend\n")

      expect(units).to eq([])
    end
  end

  describe 'determinism and errors' do
    it 'produces identical units on repeat runs' do
      create_file('spec/support/analytics_helpers.rb', "module AnalyticsHelpers\n  def b; end\n  def a; end\nend\n")
      create_file('spec/rails_helper.rb',
                  "RSpec.configure { |c| c.include AnalyticsHelpers, type: %i[system feature] }\n")

      snapshot = -> { units.map { |unit| [unit.identifier, unit.metadata, unit.dependencies] } }
      expect(snapshot.call).to eq(snapshot.call)
    end

    it 'reads source as UTF-8 whatever the default external encoding is' do
      create_file('spec/support/cafe.rb', "module CaféHelpers\n  # naïve\nend\n")

      with_posix_default_external do
        expect(unit_for('spec/support/cafe.rb').metadata[:helper_modules]).to eq(['CaféHelpers'])
      end
    end

    it 'logs and skips a file it cannot analyze' do
      create_file('spec/support/broken.rb', "module Broken\xFF\nend\n".b)
      create_file('spec/support/fine.rb', "module Fine\nend\n")

      extractor = described_class.new
      expect(extractor.extract_all.map(&:identifier)).to eq(['spec/support/fine.rb'])
      expect(logger).to have_received(:error).with(%r{spec/support/broken\.rb})
      expect(Woods::SourceInputs::ConsumerErrors.failed?(extractor)).to be(true)
    end
  end
end
