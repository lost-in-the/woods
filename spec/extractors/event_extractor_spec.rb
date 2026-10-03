# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'woods/model_name_cache'
require 'woods/extractors/shared_utility_methods'
require 'woods/extractors/shared_dependency_scanner'
require 'woods'
require 'woods/extractors/event_extractor'

RSpec.describe Woods::Extractors::EventExtractor do
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
      create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.completed")
      RUBY

      units = described_class.new.extract_all
      expect(units.first.metadata[:publishers]).to eq(['app/services/order_service.rb'])
    end

    it 'records subscriber file paths in metadata' do
      create_file('app/listeners/order_listener.rb', <<~RUBY)
        ActiveSupport::Notifications.subscribe("order.completed") { }
      RUBY

      units = described_class.new.extract_all
      expect(units.first.metadata[:subscribers]).to eq(['app/listeners/order_listener.rb'])
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

    it 'detects the paren form broadcast(:event, ...) (EXTB-3)' do
      # The publisher regex required whitespace after the method name, so
      # Wisper's README-canonical call registered no publisher — and with no
      # subscriber naming the event, no event unit existed at all.
      create_file('app/services/order_service.rb', <<~RUBY)
        class OrderService
          include Wisper::Publisher

          def call
            broadcast(:order_created, order)
            publish :order_logged
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.map(&:identifier)).to contain_exactly('order_created', 'order_logged')
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

    it 'detects .on(:event_name) as subscribers in a file with Wisper context' do
      create_file('app/controllers/orders_controller.rb', <<~RUBY)
        class OrdersController < ApplicationController
          include Wisper::Publisher

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

    # #215 / B-102. `.on(:sym)` is a generic callback-registration shape —
    # sockets, emitters, pub/sub clients all use it. Registering every match as
    # a Wisper subscriber minted phantom event units and their edges. Publishers
    # were already gated on Wisper context; subscribers were not.
    it 'ignores .on(:symbol) in a file with no Wisper context' do
      create_file('app/services/socket_client.rb', <<~RUBY)
        class SocketClient
          def connect
            socket.on(:message) { |payload| handle(payload) }
            socket.on(:close) { reconnect }
          end
        end
      RUBY

      expect(described_class.new.extract_all).to be_empty
    end

    it 'accepts Wisper context expressed without include' do
      create_file('app/listeners/order_listener.rb', <<~RUBY)
        class OrderListener
          def self.register(publisher)
            Wisper.subscribe(new)
            publisher.on(:order_created) { |o| track(o) }
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.map(&:identifier)).to eq(['order_created'])
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
      create_file('app/services/order_service.rb', <<~RUBY)
        class OrderService
          include Wisper::Publisher
          def call
            publish :order_created, order
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.first.metadata[:publishers]).to eq(['app/services/order_service.rb'])
    end

    it 'records subscriber file paths in metadata for Wisper' do
      create_file('app/controllers/orders_controller.rb', <<~RUBY)
        include Wisper::Publisher
        order_service.on(:order_created) { |o| }
      RUBY

      units = described_class.new.extract_all
      expect(units.first.metadata[:subscribers]).to eq(['app/controllers/orders_controller.rb'])
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
      create_file('app/services/order_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("order.completed")
      RUBY

      units = described_class.new.extract_all
      expect(units.first.source_code).to include('# Publishers: app/services/order_service.rb')
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependencies' do
    def edges_of(unit)
      unit.dependencies
    end

    it 'points an event at the class that publishes it, not at constants that class mentions' do
      create_file('app/services/checkout_service.rb', <<~SRC)
        class CheckoutService
          def call
            ActiveSupport::Notifications.instrument("checkout.completed")
            ShipmentService.call
            ReceiptJob.perform_later
          end
        end
      SRC

      unit = described_class.new.extract_all.first
      expect(edges_of(unit)).to eq([{ type: :class, target: 'CheckoutService', via: :published_by }])
    end

    it 'points an event at the class that subscribes to it' do
      create_file('app/listeners/receipt_listener.rb', <<~SRC)
        class ReceiptListener
          ActiveSupport::Notifications.subscribe("checkout.completed") { |*args| LedgerEntry.create! }
        end
      SRC

      unit = described_class.new.extract_all.first
      expect(edges_of(unit)).to eq([{ type: :class, target: 'ReceiptListener', via: :subscribed_by }])
    end

    it 'lists publisher edges before subscriber edges, one per file' do
      create_file('app/services/checkout_service.rb', <<~SRC)
        class CheckoutService
          ActiveSupport::Notifications.instrument("checkout.completed")
        end
      SRC
      create_file('app/services/refund_service.rb', <<~SRC)
        class RefundService
          ActiveSupport::Notifications.instrument("checkout.completed")
        end
      SRC
      create_file('app/listeners/receipt_listener.rb', <<~SRC)
        class ReceiptListener
          ActiveSupport::Notifications.subscribe("checkout.completed") {}
        end
      SRC

      unit = described_class.new.extract_all.first
      expect(edges_of(unit)).to eq(
        [
          { type: :class, target: 'CheckoutService', via: :published_by },
          { type: :class, target: 'RefundService', via: :published_by },
          { type: :class, target: 'ReceiptListener', via: :subscribed_by }
        ]
      )
    end

    it 'keeps both edges when one class publishes and subscribes to the same event' do
      create_file('app/services/widget_relay.rb', <<~SRC)
        class WidgetRelay
          ActiveSupport::Notifications.instrument("widget.moved")
          ActiveSupport::Notifications.subscribe("widget.moved") {}
        end
      SRC

      unit = described_class.new.extract_all.first
      expect(edges_of(unit)).to eq(
        [
          { type: :class, target: 'WidgetRelay', via: :published_by },
          { type: :class, target: 'WidgetRelay', via: :subscribed_by }
        ]
      )
    end

    it 'names the publisher by the constant its path governs, not the first class it declares' do
      create_file('app/services/billing/container/parser.rb', <<~SRC)
        module Billing
          class Container
            class Parser
              def call
                ActiveSupport::Notifications.instrument("billing.parsed")
              end
            end
          end
        end
      SRC

      unit = described_class.new.extract_all.first
      expect(edges_of(unit).map { |d| d[:target] }).to eq(['Billing::Container::Parser'])
    end

    it 'names a module publisher by its module name' do
      create_file('app/lib/ledger.rb', <<~SRC)
        module Ledger
          class Error < StandardError; end

          def self.close
            ActiveSupport::Notifications.instrument("ledger.closed")
          end
        end
      SRC

      unit = described_class.new.extract_all.first
      expect(edges_of(unit)).to eq([{ type: :class, target: 'Ledger', via: :published_by }])
    end

    it 'emits no edge for a file that declares no class or module' do
      create_file('app/services/order_service.rb', <<~SRC)
        ActiveSupport::Notifications.instrument("order.created", order: order)
        OrderMailer.deliver_later
      SRC

      expect(edges_of(described_class.new.extract_all.first)).to eq([])
    end

    it 'gives Wisper publishers and subscribers the same edges' do
      create_file('app/services/shipment_service.rb', <<~SRC)
        class ShipmentService
          include Wisper::Publisher
          def call
            broadcast(:shipment_sent, self)
          end
        end
      SRC
      create_file('app/listeners/shipment_listener.rb', <<~SRC)
        class ShipmentListener
          def self.wire(service)
            service.on(:shipment_sent) { Wisper.clear }
          end
        end
      SRC

      unit = described_class.new.extract_all.first
      expect(edges_of(unit)).to eq(
        [
          { type: :class, target: 'ShipmentService', via: :published_by },
          { type: :class, target: 'ShipmentListener', via: :subscribed_by }
        ]
      )
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

  # ── One read per file per run (P2) ───────────────────────────────────

  describe 'one read per file per run' do
    # A file that publishes two events (or publishes one and subscribes
    # another) was re-read once per event in pass 2 (build_unit ->
    # load_source_files), on top of the pass-1 scan_file read. The units
    # themselves are unchanged either way; the read-count assertion below
    # fails on the pre-fix shape.
    let(:bus_source) do
      <<~RUBY
        class OrderBus
          def ship
            OrderService.new.dispatch(@order)
            ActiveSupport::Notifications.instrument("order.shipped", order: @order)
            ActiveSupport::Notifications.instrument("order.paid", order: @order)
          end
        end
      RUBY
    end

    let(:listener_source) do
      <<~RUBY
        class OrderListener
          ActiveSupport::Notifications.subscribe("order.shipped") { |*args| ShippingJob.perform_later(args) }
          ActiveSupport::Notifications.subscribe("order.paid") { |*args| }
        end
      RUBY
    end

    before do
      @bus_path = create_file('app/services/order_bus.rb', bus_source)
      @listener_path = create_file('app/listeners/order_listener.rb', listener_source)
    end

    def counts_per_path
      counts = Hash.new(0)
      allow(File).to receive(:read).and_wrap_original do |method, path|
        counts[path.to_s] += 1
        method.call(path)
      end
      counts
    end

    it 'builds both shared-file events with an edge to each owning class' do
      units = described_class.new.extract_all
      by_name = units.to_h { |unit| [unit.identifier, unit] }

      expect(units.size).to eq(2)
      expect(by_name['order.shipped'].metadata[:publishers]).to eq(['app/services/order_bus.rb'])
      expect(by_name['order.shipped'].metadata[:subscribers]).to eq(['app/listeners/order_listener.rb'])
      expect(by_name['order.paid'].metadata[:publishers]).to eq(['app/services/order_bus.rb'])
      expect(by_name['order.shipped'].dependencies.map { |d| [d[:target], d[:via]] })
        .to eq([['OrderBus', :published_by], ['OrderListener', :subscribed_by]])
      expect(by_name['order.paid'].dependencies.map { |d| [d[:target], d[:via]] })
        .to eq([['OrderBus', :published_by], ['OrderListener', :subscribed_by]])
    end

    it 'names each shared file owner once for the whole run' do
      extractor = described_class.new
      allow(extractor).to receive(:governed_class_name).and_call_original

      extractor.extract_all

      expect(extractor).to have_received(:governed_class_name).with(@bus_path, anything).once
      expect(extractor).to have_received(:governed_class_name).with(@listener_path, anything).once
    end

    it 'reads each shared file once for the whole run' do
      counts = counts_per_path

      described_class.new.extract_all

      expect(counts[@bus_path]).to eq(1)
      expect(counts[@listener_path]).to eq(1)
    end
  end

  # ── Configured event_patterns ────────────────────────────────────────

  def extract_sole_unit
    units = described_class.new.extract_all
    expect(units.size).to eq(1)
    units.first
  end

  describe 'configured event_patterns' do
    let(:ledger_patterns) do
      [
        { role: :publisher, pattern: /Ledger\.emit\s*\(\s*:?["']?([\w.:-]+)/, system: :ledger },
        { role: :subscriber, pattern: /Ledger\.on\s*\(\s*:?["']?([\w.:-]+)/, system: :ledger }
      ]
    end

    before do
      # A fresh instance: spec_helper restores the previous object afterwards.
      Woods.configuration = Woods::Configuration.new
      Woods.configuration.event_patterns = ledger_patterns
    end

    it 'captures a symbol event name from a configured publisher' do
      create_file('app/services/checkout_service.rb', <<~RUBY)
        class CheckoutService
          def call
            ShipmentService.new.call
            Ledger.emit(:checkout_completed, widget_id: id)
          end
        end
      RUBY

      unit = extract_sole_unit
      expect(unit.identifier).to eq('checkout_completed')
      expect(unit.metadata[:publishers]).to eq(['app/services/checkout_service.rb'])
      expect(unit.metadata[:pattern]).to eq(:ledger)
      expect(unit.dependencies).to eq([{ type: :class, target: 'CheckoutService', via: :published_by }])
    end

    it 'captures a string event name from a configured publisher' do
      create_file('app/services/checkout_service.rb', <<~RUBY)
        Ledger.emit("checkout.completed", widget_id: id)
      RUBY

      expect(described_class.new.extract_all.map(&:identifier)).to eq(['checkout.completed'])
    end

    it 'records a configured subscriber against the publisher of the same event' do
      create_file('app/services/checkout_service.rb', 'Ledger.emit(:checkout_completed)')
      create_file('app/listeners/receipt_listener.rb', "Ledger.on('checkout_completed') { |payload| }")

      unit = extract_sole_unit
      expect(unit.metadata[:publishers]).to eq(['app/services/checkout_service.rb'])
      expect(unit.metadata[:subscribers]).to eq(['app/listeners/receipt_listener.rb'])
    end

    it 'keeps one unit per name and lists every system that used it' do
      Woods.configuration.event_patterns = ledger_patterns + [
        { role: :publisher, pattern: /Tally\.record\(\s*"([^"]+)"/, system: :tally }
      ]
      create_file('app/services/checkout_service.rb', 'Ledger.emit("checkout.completed")')
      create_file('app/services/tally_service.rb', 'Tally.record("checkout.completed")')

      unit = extract_sole_unit
      expect(unit.identifier).to eq('checkout.completed')
      expect(unit.metadata[:systems]).to contain_exactly(:ledger, :tally)
    end

    it 'lists the built-in system when it shares a name with a configured one' do
      create_file('app/services/checkout_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("checkout.completed")
        Ledger.emit("checkout.completed")
      RUBY

      unit = extract_sole_unit
      expect(unit.metadata[:pattern]).to eq(:active_support)
      expect(unit.metadata[:systems]).to eq(%i[active_support ledger])
    end

    it 'takes the event name from a (?<name>) capture and records a (?<scope>) capture' do
      Woods.configuration.event_patterns = [
        { role: :publisher, pattern: /Bus\.emit\(\s*:(?<scope>\w+),\s*:(?<name>\w+)/, system: :bus }
      ]
      create_file('app/services/checkout_service.rb', 'Bus.emit(:billing, :checkout_completed)')

      unit = extract_sole_unit
      expect(unit.identifier).to eq('checkout_completed')
      expect(unit.metadata).to include(scopes: ['billing'], sub_events: [])
    end

    it 'records scope: and event: keyword literals passed to the matched call only' do
      create_file('app/workers/receipt_worker.rb', <<~SRC)
        class ReceiptWorker
          def perform
            Ledger.emit(:checkout_completed, scope: "receipts", event: "receipt_printed")
            Ledger.emit(:checkout_completed, scope: :billing, event: outcome ? "a" : "b")
            Ledger.emit(:checkout_completed, payload: wrap(scope: "nested", event: "inner"))
            Ledger.emit(:checkout_completed, scope: "receipts")
          end
        end
      SRC

      unit = extract_sole_unit
      expect(unit.metadata).to include(scopes: %w[receipts billing], sub_events: ['receipt_printed'])
    end

    it 'records keyword literals from subscriber calls too' do
      create_file('app/listeners/receipt_listener.rb', <<~SRC)
        class ReceiptListener
          Ledger.on(:checkout_completed, scope: "receipts") { |payload| }
        end
      SRC

      expect(extract_sole_unit.metadata).to include(scopes: ['receipts'], sub_events: [])
    end

    it 'skips a match whose first capture group did not participate' do
      Woods.configuration.event_patterns = [
        { role: :publisher, pattern: /Ledger\.emit\((?::(\w+)|"([^"]+)")/, system: :ledger }
      ]
      create_file('app/services/checkout_service.rb', 'Ledger.emit("checkout.completed")')

      expect(described_class.new.extract_all).to eq([])
    end
  end

  describe 'a publisher-only wrapper with multi-line calls' do
    before do
      Woods.configuration = Woods::Configuration.new
      Woods.configuration.event_patterns = [
        { role: :publisher, pattern: /(?:::)?AuditLog\.emit\s*\(\s*["']([^"']+)["']/, system: :audit_log }
      ]
    end

    it 'captures literal names across lines and skips a call without one' do
      create_file('app/workers/maintenance_worker.rb', <<~RUBY)
        class MaintenanceWorker
          def perform
            AuditLog.emit(
              "Remove Stale Widget Images",
              scope: "maintenance_worker",
              task: "remove_stale_widget_images"
            )
            ::AuditLog.emit(
              'Carrier Tracking Update',
              scope: "carrier",
              event: outcome == :restarted ? "a" : "b"
            )
            AuditLog.emit("Inline Title", scope: "x")
            AuditLog.emit(scope: "dynamic_only")
          end
        end
      RUBY

      units = described_class.new.extract_all

      expect(units.map(&:identifier))
        .to contain_exactly('Remove Stale Widget Images', 'Carrier Tracking Update', 'Inline Title')
      expect(units.map { |u| u.metadata[:publishers] }).to all(eq(['app/workers/maintenance_worker.rb']))
      expect(units.map { |u| u.metadata[:systems] }).to all(eq([:audit_log]))
      expect(units.to_h { |u| [u.identifier, u.metadata.values_at(:scopes, :sub_events)] }).to eq(
        'Remove Stale Widget Images' => [['maintenance_worker'], []],
        'Carrier Tracking Update' => [['carrier'], []],
        'Inline Title' => [['x'], []]
      )
    end
  end

  describe 'event_paths' do
    let(:bus_source) do
      <<~SRC
        module Ledger
          class Bus
            def settle
              ActiveSupport::Notifications.instrument("ledger.settled")
            end
          end
        end
      SRC
    end

    it 'scans only app/ by default' do
      Woods.configuration = Woods::Configuration.new
      create_file('lib/ledger/bus.rb', bus_source)

      expect(described_class.new.extract_all).to eq([])
    end

    it 'scans every configured root, recording paths relative to Rails.root' do
      Woods.configuration = Woods::Configuration.new
      Woods.configuration.event_paths = %w[app lib]
      create_file('lib/ledger/bus.rb', bus_source)
      create_file('app/listeners/settlement_listener.rb', <<~SRC)
        class SettlementListener
          ActiveSupport::Notifications.subscribe("ledger.settled") {}
        end
      SRC

      unit = extract_sole_unit
      expect(unit.metadata).to include(publishers: ['lib/ledger/bus.rb'],
                                       subscribers: ['app/listeners/settlement_listener.rb'])
      expect(unit.dependencies).to eq(
        [
          { type: :class, target: 'Ledger::Bus', via: :published_by },
          { type: :class, target: 'SettlementListener', via: :subscribed_by }
        ]
      )
    end

    it 'skips a configured root that does not exist' do
      Woods.configuration = Woods::Configuration.new
      Woods.configuration.event_paths = %w[app engines/billing]
      create_file('app/services/ledger_service.rb', 'ActiveSupport::Notifications.instrument("ledger.settled")')

      expect(described_class.new.extract_all.map(&:identifier)).to eq(['ledger.settled'])
    end
  end

  describe 'without configured event_patterns' do
    it 'emits the same metadata keys as before the option existed' do
      Woods.configuration = Woods::Configuration.new
      create_file('app/services/checkout_service.rb', <<~RUBY)
        ActiveSupport::Notifications.instrument("checkout.completed")
        Ledger.emit("checkout.completed")
      RUBY

      unit = extract_sole_unit
      expect(unit.metadata.keys).to eq(%i[event_name publishers subscribers pattern publisher_count
                                          subscriber_count])
    end
  end
end
