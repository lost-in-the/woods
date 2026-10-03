# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'woods/extractor'

RSpec.describe Woods::Extractors::PoroExtractor, 'unclaimed Ruby under app/ (#672)' do
  include_context 'extractor setup'

  around do |example|
    original = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    example.run
  ensure
    Woods.configuration = original
  end

  before do
    stub_const('SweepFixture', Module.new)
    stub_const('ActiveRecord::Base', double('ActiveRecord::Base', descendants: []))
  end

  def load_source(relative, source)
    path = create_file(relative, source)
    load path
    path
  end

  def identifiers
    described_class.new.extract_all.map(&:identifier)
  end

  it 'extracts helper and view-model mixins with instance methods as module units' do
    load_source('app/helpers/date_helper.rb', <<~RUBY)
      module SweepFixture::DateHelper
        def pretty_date(value) = value.to_s
      end
    RUBY
    load_source('app/view_models/form_styling.rb', <<~RUBY)
      module SweepFixture::FormStyling
        def done_button_class = 'done'
      end
    RUBY
    units = described_class.new.extract_all
    helper = units.find { |unit| unit.identifier == 'SweepFixture::DateHelper' }
    expect(helper.metadata).to include(ruby_kind: 'module', public_methods: ['pretty_date'],
                                       discovered_via: 'unclaimed_sweep')
    expect(units.map(&:identifier)).to include('SweepFixture::FormStyling')
  end

  it 'extracts plain classes from view models, constraints, and app/lib' do
    load_source('app/view_models/sweep_fixture/billing_view.rb', <<~RUBY)
      class SweepFixture::BillingView < SimpleDelegator
        def total_label = 'Total'
      end
    RUBY
    load_source('app/constraints/sweep_fixture/non_production_constraint.rb', <<~RUBY)
      class SweepFixture::NonProductionConstraint
        def self.matches?(_request) = true
      end
    RUBY
    load_source('app/lib/sweep_fixture/slugifier.rb', <<~RUBY)
      class SweepFixture::Slugifier
        def call(text) = text.downcase
      end
    RUBY
    units = described_class.new.extract_all
    expect(units.map(&:identifier)).to contain_exactly(
      'SweepFixture::BillingView', 'SweepFixture::NonProductionConstraint', 'SweepFixture::Slugifier'
    )
    view = units.find { |unit| unit.identifier == 'SweepFixture::BillingView' }
    expect(view.metadata).to include(parent_class: 'SimpleDelegator', discovered_via: 'unclaimed_sweep')
  end

  it 'extracts a swept class through the per-file entry point incremental dispatch uses' do
    path = load_source('app/lib/sweep_fixture/tracer.rb', "class SweepFixture::Tracer\n  def call = nil\nend\n")
    expect(described_class.new.extract_poro_units(path).map(&:identifier)).to eq(['SweepFixture::Tracer'])
  end

  it 'leaves app/models units without the sweep marker' do
    load_source('app/models/sweep_fixture/money.rb', "class SweepFixture::Money\n  def cents = 0\nend\n")
    unit = described_class.new.extract_all.first
    expect(unit.identifier).to eq('SweepFixture::Money')
    expect(unit.metadata).not_to have_key(:discovered_via)
  end

  it 'never sweeps a directory another file rule owns' do
    load_source('app/services/sweep_fixture/checkout.rb', "class SweepFixture::Checkout\n  def call = nil\nend\n")
    load_source('app/assets/config/sweep_fixture/manifest.rb', "module SweepFixture::Manifest\n  X = 1\nend\n")
    expect(identifiers).to eq([])
  end

  it 'skips classes a class-discovered extractor owns while keeping their plain neighbours' do
    stub_const('ActionController::Base', Class.new)
    stub_const('Phlex::HTML', Class.new)
    load_source('app/controllers/sweep_fixture/posts_controller.rb', <<~RUBY)
      class SweepFixture::PostsController < ActionController::Base
        def index = nil
      end
    RUBY
    load_source('app/controllers/sweep_fixture/params_cleaner.rb', <<~RUBY)
      class SweepFixture::ParamsCleaner
        def call(params) = params
      end
    RUBY
    load_source('app/views/components/sweep_fixture/card.rb', <<~RUBY)
      class SweepFixture::Card < Phlex::HTML
        def view_template = nil
      end
    RUBY
    load_source('app/views/components/sweep_fixture/tailwind.rb', <<~RUBY)
      module SweepFixture::Tailwind
        def tw(*classes) = classes.join(' ')
      end
    RUBY
    expect(identifiers).to contain_exactly('SweepFixture::ParamsCleaner', 'SweepFixture::Tailwind')
  end

  it 'leaves an ActionController::Metal subclass to the controller family' do
    stub_const('ActionController::Metal', Class.new)
    load_source('app/controllers/sweep_fixture/health_controller.rb', <<~RUBY)
      class SweepFixture::HealthController < ActionController::Metal
        def show = nil
      end
    RUBY
    expect(identifiers).to eq([])
  end

  it 'does not emit a class whose canonical declaration lives in another swept file' do
    load_source('app/lib/sweep_fixture/ledger.rb', "class SweepFixture::Ledger\n  def call = nil\nend\n")
    load_source('app/lib/sweep_fixture/ledger_extension.rb', "class SweepFixture::Ledger\n  def extra = nil\nend\n")
    expect(identifiers).to eq(['SweepFixture::Ledger'])
  end

  it 'follows the configured globs and still scans app/models' do
    Woods.configuration.unclaimed_ruby_paths = ['app/helpers/**/*.rb']
    load_source('app/helpers/sweep_fixture/date_helper.rb', "module SweepFixture::DateHelper\n  def d = 1\nend\n")
    load_source('app/lib/sweep_fixture/tracer.rb', "class SweepFixture::Tracer\n  def call = nil\nend\n")
    load_source('app/models/sweep_fixture/value.rb', "class SweepFixture::Value\n  def call = nil\nend\n")
    expect(identifiers).to contain_exactly('SweepFixture::DateHelper', 'SweepFixture::Value')
  end

  describe 'top-level constant assignment files' do
    it 'emits one constant unit per owned assignment with its value kind' do
      stub_const('SweepFixture::Billing', Module.new)
      load_source('app/models/sweep_fixture/patterns.rb', <<~'RUBY')
        SweepFixture::EmailPattern = /\A[^@\s]+@[^@\s]+\z/
        SweepFixture::ReservedNames = %w[admin root].freeze
        SweepFixture::Billing::Countries = { 'CA' => 'Canada' }.freeze
      RUBY
      units = described_class.new.extract_all
      expect(units.to_h { |unit| [unit.identifier, unit.metadata.values_at(:ruby_kind, :value_kind)] }).to eq(
        'SweepFixture::EmailPattern' => %w[constant regexp],
        'SweepFixture::ReservedNames' => %w[constant array],
        'SweepFixture::Billing::Countries' => %w[constant hash]
      )
      countries = units.find { |unit| unit.identifier == 'SweepFixture::Billing::Countries' }
      expect(countries.namespace).to eq('SweepFixture::Billing')
      expect(countries.source_code).to include("{ 'CA' => 'Canada' }")
      expect(countries.source_code).not_to include('EmailPattern')
    end

    it 'skips aliases of modules and constants owned by another file' do
      load_source('app/lib/sweep_fixture/limits.rb', "SweepFixture::Limit = 3\n")
      load_source('app/lib/sweep_fixture/aliases.rb', "SweepFixture::Alias = SweepFixture\nSweepFixture::Limit = 4\n")
      expect(identifiers).to eq(['SweepFixture::Limit'])
    end

    it 'leaves constants inside a class or module body to their owner' do
      load_source('app/models/sweep_fixture/settings.rb', "module SweepFixture::Settings\n  LIMIT = 3\nend\n")
      expect(identifiers).to eq(['SweepFixture::Settings'])
    end
  end

  describe '#extract_fallback_units for a claimed path whose owner emitted nothing' do
    it 'extracts helper classes and mixins beside a serializer base' do
      path = load_source('app/serializers/sweep_fixture/serializer_helpers.rb', <<~RUBY)
        module SweepFixture::SerializerHelpers
          def money(value) = value.to_s
        end
        class SweepFixture::Formatter
          def call(value) = value
        end
      RUBY
      units = described_class.new.extract_fallback_units(path)
      expect(units.map(&:identifier)).to contain_exactly('SweepFixture::Formatter', 'SweepFixture::SerializerHelpers')
      expect(units.map { |unit| unit.metadata[:discovered_via] }.uniq).to eq(['owner_fallback'])
    end

    it 'applies the class-family exclusion and canonical ownership like the sweep' do
      stub_const('ActionController::Base', Class.new)
      path = load_source('app/services/sweep_fixture/base_controller.rb', <<~RUBY)
        class SweepFixture::BaseController < ActionController::Base
          def index = nil
        end
      RUBY
      load_source('app/services/sweep_fixture/owned.rb', "class SweepFixture::Owned\n  def a = 1\nend\n")
      reopen = load_source('app/services/sweep_fixture/reopen.rb', "class SweepFixture::Owned\n  def b = 2\nend\n")
      extractor = described_class.new
      expect(extractor.extract_fallback_units(path)).to eq([])
      expect(extractor.extract_fallback_units(reopen)).to eq([])
    end

    context 'with GraphQL helpers the graphql extractor does not admit' do
      before do
        stub_const('GraphQL::Schema', Class.new)
        stub_const('GraphQL::Schema::Object', Class.new)
        stub_const('GraphQL::Schema::Field', Class.new)
        stub_const('GraphQL::Batch::Loader', Class.new)
      end

      def fallback(relative, source)
        described_class.new.extract_fallback_units(load_source(relative, source)).map(&:identifier)
      end

      it 'keeps batch loaders, custom fields, and a superclass-less resolver base' do
        expect(fallback('app/graphql/sweep_fixture/association_loader.rb', <<~RUBY)).to eq(['SweepFixture::AssociationLoader'])
          class SweepFixture::AssociationLoader < GraphQL::Batch::Loader
            def initialize(model, assoc) = nil
          end
        RUBY
        expect(fallback('app/graphql/sweep_fixture/authorized_field.rb', <<~RUBY)).to eq(['SweepFixture::AuthorizedField'])
          class SweepFixture::AuthorizedField < GraphQL::Schema::Field
            def initialize(*args, required_permission: nil, **kwargs, &block) = nil
          end
        RUBY
        stub_const('Resolvers', Module.new)
        resolver_base = "class Resolvers::Base\n  def initialize(a = nil) = nil\nend\n"
        expect(fallback('app/graphql/resolvers/base.rb', resolver_base))
          .to eq(['Resolvers::Base'])
      end

      it 'leaves schema types and Resolvers::Base subclasses to the graphql extractor' do
        stub_const('Resolvers', Module.new)
        load_source('app/graphql/resolvers/base.rb', "class Resolvers::Base\n  def initialize(a = nil) = nil\nend\n")
        orders = "class Resolvers::Orders < Resolvers::Base\n  def x = 1\nend\n"
        expect(fallback('app/graphql/resolvers/orders.rb', orders))
          .to eq([])
        expect(fallback('app/graphql/sweep_fixture/order_type.rb', <<~RUBY)).to eq([])
          class SweepFixture::OrderType < GraphQL::Schema::Object
            def id = 1
          end
        RUBY
      end

      it 'keeps plain and nested GraphQL mixins' do
        expect(fallback('app/graphql/sweep_fixture/version_capabilities.rb', <<~RUBY)).to eq(['SweepFixture::VersionCapabilities'])
          module SweepFixture::VersionCapabilities
            def self.supports?(cap, version) = true
          end
        RUBY
        stub_const('Types', Module.new)
        expect(fallback('app/graphql/types/positive_number_concern.rb', <<~RUBY)).to eq(['Types::PositiveNumberConcern'])
          module Types
            module PositiveNumberConcern
              def check_positive(value) = value.positive?
            end
          end
        RUBY
      end
    end

    it 'keeps module_function and deeply nested service modules' do
      units = described_class.new.extract_fallback_units(load_source('app/services/sweep_fixture/consumer.rb', <<~RUBY))
        module SweepFixture
          module Products
            module Files
              module LinkNormalizer
                def self.allowed?(url) = true
              end
            end
          end
          module AnalyticsConsumer
            module_function
            def all = []
          end
        end
      RUBY
      expect(units.map(&:identifier)).to contain_exactly('SweepFixture::Products::Files::LinkNormalizer',
                                                         'SweepFixture::AnalyticsConsumer')
    end

    it 'lists fallback candidates with every extractor that owns each one' do
      helper = create_file('app/serializers/serializer_helpers.rb', "module SerializerHelpers; end\n")
      policy = create_file('app/policies/post_policy.rb', "class PostPolicy; end\n")
      create_file('app/helpers/date_helper.rb', "module DateHelper; end\n")
      expect(described_class.new.fallback_files).to eq(helper => %i[serializers],
                                                       policy => %i[
                                                         policies pundit_policies
                                                       ])
    end

    it 'leaves the sweep and app/models scans unchanged' do
      load_source('app/services/sweep_fixture/checkout.rb', "class SweepFixture::Checkout\n  def call = nil\nend\n")
      expect(identifiers).to eq([])
    end
  end

  it 'parses through an injected collector so a run can share one parse per file' do
    require 'woods/source_references/memo_collector'
    path = load_source('app/lib/sweep_fixture/tracer.rb', "class SweepFixture::Tracer\n  def call = nil\nend\n")
    inner = Woods::SourceReferences::Collector.new
    allow(inner).to receive(:call).and_call_original
    extractor = described_class.new
    extractor.collector = Woods::SourceReferences::MemoCollector.new(collector: inner)

    extractor.extract_poro_units(path)
    extractor.extract_poro_units(path)
    expect(inner).to have_received(:call).once
  end

  it 'reconciles standalone modules across the swept scope' do
    path = load_source('app/helpers/sweep_fixture/link_helper.rb',
                       "module SweepFixture::LinkHelper\n  def link = 1\nend\n")
    expect(described_class.new.standalone_modules.fetch(path).map(&:identifier)).to eq(['SweepFixture::LinkHelper'])
  end
end
