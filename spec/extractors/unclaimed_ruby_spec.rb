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

  it 'reconciles standalone modules across the swept scope' do
    path = load_source('app/helpers/sweep_fixture/link_helper.rb',
                       "module SweepFixture::LinkHelper\n  def link = 1\nend\n")
    expect(described_class.new.standalone_modules.fetch(path).map(&:identifier)).to eq(['SweepFixture::LinkHelper'])
  end
end
