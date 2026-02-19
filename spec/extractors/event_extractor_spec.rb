# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/model_name_cache'
require 'codebase_index/extractors/shared_utility_methods'
require 'codebase_index/extractors/shared_dependency_scanner'
require 'codebase_index/extractors/event_extractor'

RSpec.describe CodebaseIndex::Extractors::EventExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing app directory gracefully' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── extract_all — general ────────────────────────────────────────────

  describe '#extract_all' do
    it 'returns empty array for files without event patterns' do
      create_file('app/models/user.rb', <<~RUBY)
        class User < ApplicationRecord
          has_many :orders
        end
      RUBY

      units = described_class.new.extract_all
      expect(units).to eq([])
    end

    it 'scans all app/ subdirectories' do
      create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.created", order: order)
      RUBY

      create_file('app/controllers/orders_controller.rb', <<~RUBY)
        ActiveSupport::Notifications.subscribe("order.created") { |*args| }
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('order.created')
    end
  end

  # ── ActiveSupport::Notifications ─────────────────────────────────────

  describe 'ActiveSupport::Notifications' do
    it 'detects instrument calls as publishers' do
      create_file('app/services/order_service.rb', <<~RUBY)
        class OrderService
          def call
            ActiveSupport::Notifications.instrument("order.completed", order: @order)
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)

      unit = units.first
      expect(unit.type).to eq(:event)
      expect(unit.identifier).to eq('order.completed')
    end

    it 'detects subscribe calls as subscribers' do
      create_file('app/listeners/order_listener.rb', <<~RUBY)
        class OrderListener
          ActiveSupport::Notifications.subscribe("order.completed") do |name, started, finished, unique_id, data|
            Rails.logger.info("Order completed")
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('order.completed')
    end

    it 'merges publishers and subscribers for the same event name' do
      create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.completed", order: order)
      RUBY

      create_file('app/listeners/order_listener.rb', <<~RUBY)
        ActiveSupport::Notifications.subscribe("order.completed") { |*args| }
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)

      unit = units.first
      meta = unit.metadata
      expect(meta[:publishers].size).to eq(1)
      expect(meta[:subscribers].size).to eq(1)
    end

    it 'produces one unit per unique event name' do
      create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.created", order: order)
        ActiveSupport::Notifications.instrument("order.completed", order: order)
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
      identifiers = units.map(&:identifier)
      expect(identifiers).to contain_exactly('order.created', 'order.completed')
    end

    it 'records publisher file paths in metadata' do
      publisher_path = create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.completed")
      RUBY

      units = described_class.new.extract_all
      expect(units.first.metadata[:publishers]).to include(publisher_path)
    end

    it 'records subscriber file paths in metadata' do
      subscriber_path = create_file('app/listeners/order_listener.rb', <<~RUBY)
        ActiveSupport::Notifications.subscribe("order.completed") { }
      RUBY

      units = described_class.new.extract_all
      expect(units.first.metadata[:subscribers]).to include(subscriber_path)
    end

    it 'does not duplicate the same file in publishers list' do
      create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.completed", step: :a)
        ActiveSupport::Notifications.instrument("order.completed", step: :b)
      RUBY

      units = described_class.new.extract_all
      expect(units.first.metadata[:publishers].size).to eq(1)
    end

    it 'sets pattern to :active_support' do
      create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.completed")
      RUBY

      units = described_class.new.extract_all
      expect(units.first.metadata[:pattern]).to eq(:active_support)
    end

    it 'sets file_path to the first publisher path' do
      publisher_path = create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.completed")
      RUBY

      units = described_class.new.extract_all
      expect(units.first.file_path).to eq(publisher_path)
    end

    it 'handles double-quoted event names' do
      create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.created", order: order)
      RUBY

      units = described_class.new.extract_all
      expect(units.first.identifier).to eq('order.created')
    end

    it 'handles single-quoted event names' do
      create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument('order.created', order: order)
      RUBY

      units = described_class.new.extract_all
      expect(units.first.identifier).to eq('order.created')
    end
  end

  # ── Wisper ────────────────────────────────────────────────────────────

  describe 'Wisper' do
    it 'detects publish calls as publishers in Wisper context' do
      create_file('app/services/order_service.rb', <<~RUBY)
        class OrderService
          include Wisper::Publisher

          def call
            publish :order_created, order
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('order_created')
    end

    it 'detects broadcast calls as publishers in Wisper context' do
      create_file('app/services/order_service.rb', <<~RUBY)
        class OrderService
          include Wisper::Publisher

          def call
            broadcast :order_completed, order
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('order_completed')
    end

    it 'detects .on(:event_name) as subscribers' do
      create_file('app/controllers/orders_controller.rb', <<~RUBY)
        class OrdersController < ApplicationController
          def create
            order_service.on(:order_created) { |order| redirect_to order }
            order_service.call
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('order_created')
    end

    it 'does not detect publish without Wisper context' do
      create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          def publish_to_stream
            publish :event  # not Wisper
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units).to eq([])
    end

    it 'sets pattern to :wisper' do
      create_file('app/services/order_service.rb', <<~RUBY)
        class OrderService
          include Wisper::Publisher
          def call
            publish :order_created, order
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.first.metadata[:pattern]).to eq(:wisper)
    end

    it 'records publisher file paths in metadata for Wisper' do
      publisher_path = create_file('app/services/order_service.rb', <<~RUBY)
        class OrderService
          include Wisper::Publisher
          def call
            publish :order_created, order
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.first.metadata[:publishers]).to include(publisher_path)
    end

    it 'records subscriber file paths in metadata for Wisper' do
      subscriber_path = create_file('app/controllers/orders_controller.rb', <<~RUBY)
        order_service.on(:order_created) { |o| }
      RUBY

      units = described_class.new.extract_all
      expect(units.first.metadata[:subscribers]).to include(subscriber_path)
    end
  end

  # ── scan_file ─────────────────────────────────────────────────────────

  describe '#scan_file' do
    it 'handles read errors gracefully' do
      event_map = {}
      expect do
        described_class.new.scan_file('/nonexistent/file.rb', event_map)
      end.not_to raise_error
      expect(event_map).to be_empty
    end
  end

  # ── Metadata ─────────────────────────────────────────────────────────

  describe 'metadata' do
    it 'includes all expected keys' do
      create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.completed")
      RUBY

      units = described_class.new.extract_all
      meta = units.first.metadata

      expect(meta).to have_key(:event_name)
      expect(meta).to have_key(:publishers)
      expect(meta).to have_key(:subscribers)
      expect(meta).to have_key(:pattern)
      expect(meta).to have_key(:publisher_count)
      expect(meta).to have_key(:subscriber_count)
    end

    it 'counts publishers and subscribers correctly' do
      create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.completed")
      RUBY
      create_file('app/services/payment_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.completed")
      RUBY
      create_file('app/listeners/order_listener.rb', <<~RUBY)
        ActiveSupport::Notifications.subscribe("order.completed") { }
      RUBY

      units = described_class.new.extract_all
      meta = units.first.metadata
      expect(meta[:publisher_count]).to eq(2)
      expect(meta[:subscriber_count]).to eq(1)
    end

    it 'sets event_name in metadata' do
      create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.completed")
      RUBY

      units = described_class.new.extract_all
      expect(units.first.metadata[:event_name]).to eq('order.completed')
    end
  end

  # ── Source annotation ────────────────────────────────────────────────

  describe 'source_code' do
    it 'includes event name in annotation' do
      create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.completed")
      RUBY

      units = described_class.new.extract_all
      expect(units.first.source_code).to include('# Event: order.completed')
    end

    it 'includes publisher paths in annotation' do
      publisher_path = create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.completed")
      RUBY

      units = described_class.new.extract_all
      expect(units.first.source_code).to include(publisher_path)
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependencies' do
    it 'includes :via key on all dependencies' do
      create_file('app/services/order_service.rb', <<~RUBY)
        class OrderService
          def call
            ActiveSupport::Notifications.instrument("order.completed")
            NotifyService.call
            CleanupJob.perform_later
          end
        end
      RUBY

      units = described_class.new.extract_all
      units.first.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end
  end

  # ── Serialization round-trip ─────────────────────────────────────────

  describe 'serialization' do
    it 'to_h round-trips correctly' do
      create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.completed", order: @order)
      RUBY
      create_file('app/listeners/order_listener.rb', <<~RUBY)
        ActiveSupport::Notifications.subscribe("order.completed") { |*args| }
      RUBY

      units = described_class.new.extract_all
      hash = units.first.to_h

      expect(hash[:type]).to eq(:event)
      expect(hash[:identifier]).to eq('order.completed')
      expect(hash[:source_hash]).to be_a(String)
      expect(hash[:extracted_at]).to be_a(String)

      # JSON round-trip
      json = JSON.generate(hash)
      parsed = JSON.parse(json)
      expect(parsed['type']).to eq('event')
      expect(parsed['identifier']).to eq('order.completed')
    end
  end
end
