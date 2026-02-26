# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'codebase_index/model_name_cache'
require 'codebase_index/extractors/shared_utility_methods'
require 'codebase_index/extractors/shared_dependency_scanner'
require 'codebase_index/extractors/poro_extractor'

RSpec.describe CodebaseIndex::Extractors::PoroExtractor do
  include_context 'extractor setup'

  # Stub ActiveRecord::Base.descendants used in extract_all
  let(:ar_base) do
    double('ActiveRecord::Base').tap do |ar|
      allow(ar).to receive(:descendants).and_return([])
    end
  end

  before do
    stub_const('ActiveRecord::Base', ar_base)
  end

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing app/models directory gracefully' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'extracts PORO classes from app/models/' do
      create_file('app/models/money.rb', <<~RUBY)
        class Money
          attr_reader :amount, :currency

          def initialize(amount, currency:)
            @amount = amount
            @currency = currency
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:poro)
      expect(units.first.identifier).to eq('Money')
    end

    it 'skips ActiveRecord descendants' do
      ar_model = double('User', name: 'User')
      allow(ar_base).to receive(:descendants).and_return([ar_model])

      create_file('app/models/user.rb', 'class User < ApplicationRecord; end')

      units = described_class.new.extract_all
      expect(units).to be_empty
    end

    it 'skips files in app/models/concerns/' do
      create_file('app/models/concerns/timestampable.rb', <<~RUBY)
        module Timestampable
          def self.included(base)
            base.before_save :set_timestamps
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units).to be_empty
    end

    it 'skips module-only files' do
      create_file('app/models/reportable.rb', <<~RUBY)
        module Reportable
        end
      RUBY

      units = described_class.new.extract_all
      expect(units).to be_empty
    end

    it 'captures Struct.new files' do
      create_file('app/models/address.rb', <<~RUBY)
        Address = Struct.new(:street, :city, :zip)
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Address')
    end

    it 'captures Data.define files' do
      create_file('app/models/coordinates.rb', <<~RUBY)
        Coordinates = Data.define(:lat, :lng)
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Coordinates')
    end

    it 'captures CurrentAttributes subclasses' do
      create_file('app/models/current.rb', <<~RUBY)
        class Current < ActiveSupport::CurrentAttributes
          attribute :user, :account
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Current')
    end

    it 'extracts namespaced classes from subdirectories' do
      create_file('app/models/order/update.rb', <<~RUBY)
        class Order::Update
          def initialize(order, params)
            @order = order
            @params = params
          end

          def call
            @order.update!(@params)
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Order::Update')
    end

    it 'skips files with no class keyword and no PORO patterns' do
      create_file('app/models/constants.rb', <<~RUBY)
        VALID_STATUSES = %w[pending active cancelled].freeze
      RUBY

      units = described_class.new.extract_all
      expect(units).to be_empty
    end

    it 'discovers files in nested subdirectories' do
      create_file('app/models/billing/adjustment.rb', <<~RUBY)
        class Billing::Adjustment
          def apply(amount); end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
    end
  end

  # ── extract_poro_file ────────────────────────────────────────────────

  describe '#extract_poro_file' do
    it 'extracts a basic PORO class' do
      path = create_file('app/models/money.rb', <<~RUBY)
        class Money
          attr_reader :amount

          def initialize(amount)
            @amount = amount
          end

          def to_s
            "$#{@amount}"
          end
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      expect(unit).not_to be_nil
      expect(unit.type).to eq(:poro)
      expect(unit.identifier).to eq('Money')
      expect(unit.file_path).to eq(path)
    end

    it 'returns nil for module-only files' do
      path = create_file('app/models/reportable.rb', <<~RUBY)
        module Reportable
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      expect(unit).to be_nil
    end

    it 'returns nil for files with no class or PORO patterns' do
      path = create_file('app/models/constants.rb', <<~RUBY)
        VALID_STATUSES = %w[pending active cancelled].freeze
      RUBY

      unit = described_class.new.extract_poro_file(path)
      expect(unit).to be_nil
    end

    it 'returns nil for non-existent files' do
      unit = described_class.new.extract_poro_file('/nonexistent/path.rb')
      expect(unit).to be_nil
    end

    it 'sets namespace for namespaced classes' do
      path = create_file('app/models/order/update.rb', <<~RUBY)
        class Order::Update
          def call; end
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      expect(unit.namespace).to eq('Order')
    end

    it 'sets namespace to nil for top-level classes' do
      path = create_file('app/models/money.rb', 'class Money; end')

      unit = described_class.new.extract_poro_file(path)
      expect(unit.namespace).to be_nil
    end

    it 'includes source_code with annotation header' do
      path = create_file('app/models/money.rb', <<~RUBY)
        class Money
          def to_s; end
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      expect(unit.source_code).to include('# ║ PORO: Money')
      expect(unit.source_code).to include('def to_s')
    end

    it 'extracts Struct.new patterns' do
      path = create_file('app/models/address.rb', <<~RUBY)
        Address = Struct.new(:street, :city, :zip)
      RUBY

      unit = described_class.new.extract_poro_file(path)
      expect(unit).not_to be_nil
      expect(unit.identifier).to eq('Address')
    end

    it 'extracts Data.define patterns' do
      path = create_file('app/models/coordinates.rb', <<~RUBY)
        Coordinates = Data.define(:lat, :lng)
      RUBY

      unit = described_class.new.extract_poro_file(path)
      expect(unit).not_to be_nil
      expect(unit.identifier).to eq('Coordinates')
    end

    it 'all dependencies include :via key' do
      path = create_file('app/models/order_summary.rb', <<~RUBY)
        class OrderSummary
          def send_receipt
            UserMailer.receipt.deliver_later
          end
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      unit.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end
  end

  # ── Metadata ─────────────────────────────────────────────────────────

  describe 'metadata' do
    it 'includes public_methods' do
      path = create_file('app/models/money.rb', <<~RUBY)
        class Money
          def to_s
            "$#{@amount}"
          end

          def +(other)
            Money.new(@amount + other.amount)
          end

          private

          def validate!
            raise "negative" if @amount < 0
          end
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      expect(unit.metadata[:public_methods]).to include('to_s')
      expect(unit.metadata[:public_methods]).not_to include('validate!')
    end

    it 'includes class_methods' do
      path = create_file('app/models/money.rb', <<~RUBY)
        class Money
          def self.zero
            new(0)
          end
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      expect(unit.metadata[:class_methods]).to include('zero')
    end

    it 'includes initialize_params' do
      path = create_file('app/models/money.rb', <<~RUBY)
        class Money
          def initialize(amount, currency: 'USD')
          end
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      expect(unit.metadata[:initialize_params]).not_to be_empty
      names = unit.metadata[:initialize_params].map { |p| p[:name] }
      expect(names).to include('amount', 'currency')
    end

    it 'includes parent_class' do
      path = create_file('app/models/current.rb', <<~RUBY)
        class Current < ActiveSupport::CurrentAttributes
          attribute :user
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      expect(unit.metadata[:parent_class]).to eq('ActiveSupport::CurrentAttributes')
    end

    it 'sets parent_class to nil for classes without explicit parent' do
      path = create_file('app/models/money.rb', 'class Money; end')

      unit = described_class.new.extract_poro_file(path)
      expect(unit.metadata[:parent_class]).to be_nil
    end

    it 'includes loc count' do
      path = create_file('app/models/money.rb', <<~RUBY)
        class Money
          def to_s
            "money"
          end
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      expect(unit.metadata[:loc]).to be_a(Integer)
      expect(unit.metadata[:loc]).to be > 0
    end

    it 'includes method_count' do
      path = create_file('app/models/money.rb', <<~RUBY)
        class Money
          def to_s; end
          def inspect; end
          def self.zero; end
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      expect(unit.metadata[:method_count]).to eq(3)
    end

    it 'includes all expected metadata keys' do
      path = create_file('app/models/money.rb', 'class Money; end')
      unit = described_class.new.extract_poro_file(path)
      meta = unit.metadata

      expect(meta).to have_key(:public_methods)
      expect(meta).to have_key(:class_methods)
      expect(meta).to have_key(:initialize_params)
      expect(meta).to have_key(:parent_class)
      expect(meta).to have_key(:loc)
      expect(meta).to have_key(:method_count)
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependencies' do
    it 'detects service dependencies via SharedDependencyScanner' do
      path = create_file('app/models/order_summary.rb', <<~RUBY)
        class OrderSummary
          def total
            PricingService.calculate(items)
          end
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      service_dep = unit.dependencies.find { |d| d[:type] == :service && d[:target] == 'PricingService' }
      expect(service_dep).not_to be_nil
    end

    it 'detects job dependencies via SharedDependencyScanner' do
      path = create_file('app/models/order_summary.rb', <<~RUBY)
        class OrderSummary
          def notify
            NotificationJob.perform_later(id)
          end
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      job_dep = unit.dependencies.find { |d| d[:type] == :job && d[:target] == 'NotificationJob' }
      expect(job_dep).not_to be_nil
    end

    it 'detects mailer dependencies via SharedDependencyScanner' do
      path = create_file('app/models/order_summary.rb', <<~RUBY)
        class OrderSummary
          def send_receipt
            UserMailer.receipt.deliver_later
          end
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      mailer_dep = unit.dependencies.find { |d| d[:type] == :mailer && d[:target] == 'UserMailer' }
      expect(mailer_dep).not_to be_nil
    end

    it 'returns empty dependencies for simple PORO with no references' do
      path = create_file('app/models/money.rb', <<~RUBY)
        class Money
          def initialize(amount)
            @amount = amount
          end
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      expect(unit.dependencies).to be_an(Array)
    end
  end

  # ── Serialization round-trip ─────────────────────────────────────────

  describe 'serialization' do
    it 'to_h round-trips correctly' do
      path = create_file('app/models/money.rb', <<~RUBY)
        class Money
          def initialize(amount)
            @amount = amount
          end
        end
      RUBY

      unit = described_class.new.extract_poro_file(path)
      hash = unit.to_h

      expect(hash[:type]).to eq(:poro)
      expect(hash[:identifier]).to eq('Money')
      expect(hash[:source_code]).to include('Money')
      expect(hash[:source_hash]).to be_a(String)
      expect(hash[:extracted_at]).to be_a(String)

      json = JSON.generate(hash)
      parsed = JSON.parse(json)
      expect(parsed['type']).to eq('poro')
      expect(parsed['identifier']).to eq('Money')
    end
  end
end
