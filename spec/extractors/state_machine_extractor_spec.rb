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
require 'codebase_index/extractors/state_machine_extractor'

RSpec.describe CodebaseIndex::Extractors::StateMachineExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing app/models directory gracefully' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers state machines in app/models/' do
      create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:state_machine)
    end

    it 'discovers model files in subdirectories' do
      create_file('app/models/billing/invoice.rb', <<~RUBY)
        class Billing::Invoice < ApplicationRecord
          include AASM
          aasm do
            state :draft, initial: true
            state :sent
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Billing::Invoice::aasm')
    end

    it 'returns empty array for models without state machines' do
      create_file('app/models/user.rb', <<~RUBY)
        class User < ApplicationRecord
          has_many :orders
        end
      RUBY

      units = described_class.new.extract_all
      expect(units).to eq([])
    end
  end

  # ── AASM ─────────────────────────────────────────────────────────────

  describe '#extract_model_file — AASM' do
    it 'detects AASM state machine' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :processing
            state :completed
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.size).to eq(1)

      unit = units.first
      expect(unit.type).to eq(:state_machine)
      expect(unit.identifier).to eq('Order::aasm')
      expect(unit.file_path).to eq(path)
    end

    it 'extracts states from AASM block' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :processing
            state :completed
            state :cancelled
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:states]).to contain_exactly('pending', 'processing', 'completed', 'cancelled')
    end

    it 'detects initial state from state declaration' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:initial_state]).to eq('pending')
    end

    it 'detects initial state from aasm declaration' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm initial: :pending do
            state :pending
            state :completed
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:initial_state]).to eq('pending')
    end

    it 'extracts events with transitions' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :processing

            event :start_processing do
              transitions from: :pending, to: :processing
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      events = units.first.metadata[:events]
      expect(events.size).to eq(1)
      expect(events.first[:name]).to eq('start_processing')
      expect(events.first[:transitions]).to eq([{ from: 'pending', to: 'processing', guard: nil }])
    end

    it 'extracts event transitions with guards' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed

            event :complete do
              transitions from: :pending, to: :completed, guard: :valid?
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      transition = units.first.metadata[:events].first[:transitions].first
      expect(transition[:guard]).to eq('valid?')
    end

    it 'extracts multiple events' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :processing
            state :completed

            event :start do
              transitions from: :pending, to: :processing
            end

            event :finish do
              transitions from: :processing, to: :completed
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      events = units.first.metadata[:events]
      expect(events.map { |e| e[:name] }).to contain_exactly('start', 'finish')
    end

    it 'sets gem_detected to aasm' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:gem_detected]).to eq('aasm')
    end

    it 'extracts callbacks' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed

            after_transition do |order, transition|
              order.notify_customer
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:callbacks]).not_to be_empty
    end

    it 'sets source_code with annotation header' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.source_code).to include('# State machine (aasm) for Order')
    end

    it 'returns empty array for files without AASM' do
      path = create_file('app/models/user.rb', <<~RUBY)
        class User < ApplicationRecord
          has_many :orders
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units).to eq([])
    end
  end

  # ── Statesman ────────────────────────────────────────────────────────

  describe '#extract_model_file — Statesman' do
    it 'detects Statesman state machine' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include Statesman::Machine

          state :pending, initial: true
          state :processing
          state :completed
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.size).to eq(1)

      unit = units.first
      expect(unit.type).to eq(:state_machine)
      expect(unit.identifier).to eq('Order::statesman')
    end

    it 'extracts states from Statesman source' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include Statesman::Machine

          state :pending, initial: true
          state :processing
          state :completed
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:states]).to contain_exactly('pending', 'processing', 'completed')
    end

    it 'detects initial state from Statesman declaration' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include Statesman::Machine

          state :pending, initial: true
          state :completed
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:initial_state]).to eq('pending')
    end

    it 'extracts transitions from Statesman source' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include Statesman::Machine

          state :pending, initial: true
          state :processing
          state :completed

          transition from: :pending, to: :processing
          transition from: :processing, to: :completed
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      transitions = units.first.metadata[:transitions]
      expect(transitions.size).to eq(2)
      expect(transitions.first).to eq({ from: 'pending', to: 'processing', guard: nil })
    end

    it 'sets gem_detected to statesman' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include Statesman::Machine
          state :pending, initial: true
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:gem_detected]).to eq('statesman')
    end

    it 'returns empty events array for Statesman (uses transitions not events)' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include Statesman::Machine
          state :pending, initial: true
          transition from: :pending, to: :completed
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:events]).to eq([])
    end
  end

  # ── state_machines gem ────────────────────────────────────────────────

  describe '#extract_model_file — state_machines gem' do
    it 'detects state_machine block' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine :status, initial: :pending do
            state :pending
            state :active
            state :completed
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.size).to eq(1)

      unit = units.first
      expect(unit.type).to eq(:state_machine)
      expect(unit.identifier).to eq('Order::state_machine_status')
    end

    it 'extracts states from state_machines block' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine :status, initial: :pending do
            state :pending
            state :active
            state :completed
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:states]).to contain_exactly('pending', 'active', 'completed')
    end

    it 'detects initial state from state_machine declaration' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine :status, initial: :pending do
            state :pending
            state :active
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:initial_state]).to eq('pending')
    end

    it 'extracts events with transitions from state_machines block' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine :status, initial: :pending do
            state :pending
            state :active

            event :activate do
              transition pending: :active
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      events = units.first.metadata[:events]
      expect(events.size).to eq(1)
      expect(events.first[:name]).to eq('activate')
      expect(events.first[:transitions]).to eq([{ from: 'pending', to: 'active', guard: nil }])
    end

    it 'sets gem_detected to state_machines' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine :status do
            state :pending
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:gem_detected]).to eq('state_machines')
    end

    it 'produces multiple units for multiple state_machine blocks' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine :status, initial: :pending do
            state :pending
            state :active
          end

          state_machine :payment_status, initial: :unpaid do
            state :unpaid
            state :paid
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.size).to eq(2)
      identifiers = units.map(&:identifier)
      expect(identifiers).to contain_exactly(
        'Order::state_machine_status',
        'Order::state_machine_payment_status'
      )
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependencies' do
    it 'includes a reference to the host model' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      deps = units.first.dependencies
      model_dep = deps.find { |d| d[:type] == :model && d[:target] == 'Order' }
      expect(model_dep).not_to be_nil
      expect(model_dep[:via]).to eq(:state_machine)
    end

    it 'scans callbacks for service dependencies' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed
            after_transition { |o| NotificationService.call(o) }
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      dep_targets = units.first.dependencies.map { |d| d[:target] }
      expect(dep_targets).to include('NotificationService')
    end

    it 'includes :via key on all dependencies' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            after_transition { |o| NotifyJob.perform_later(o) }
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      units.first.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end
  end

  # ── Error handling ───────────────────────────────────────────────────

  describe 'error handling' do
    it 'returns empty array for nonexistent file' do
      units = described_class.new.extract_model_file('/nonexistent/path/model.rb')
      expect(units).to eq([])
    end
  end

  # ── Namespace ────────────────────────────────────────────────────────

  describe 'namespace' do
    it 'sets namespace for namespaced models' do
      path = create_file('app/models/billing/invoice.rb', <<~RUBY)
        class Billing::Invoice < ApplicationRecord
          include AASM
          aasm do
            state :draft, initial: true
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.namespace).to eq('Billing')
    end

    it 'sets nil namespace for top-level models' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.namespace).to be_nil
    end
  end

  # ── Metadata ─────────────────────────────────────────────────────────

  describe 'metadata' do
    it 'includes all expected keys' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed

            event :complete do
              transitions from: :pending, to: :completed
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      meta = units.first.metadata

      expect(meta).to have_key(:gem_detected)
      expect(meta).to have_key(:states)
      expect(meta).to have_key(:events)
      expect(meta).to have_key(:transitions)
      expect(meta).to have_key(:initial_state)
      expect(meta).to have_key(:callbacks)
      expect(meta).to have_key(:model_name)
    end

    it 'populates transitions from events' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed

            event :complete do
              transitions from: :pending, to: :completed
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      meta = units.first.metadata
      expect(meta[:transitions]).to eq([{ from: 'pending', to: 'completed', guard: nil }])
    end
  end

  # ── Serialization round-trip ─────────────────────────────────────────

  describe 'serialization' do
    it 'to_h round-trips correctly' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed

            event :complete do
              transitions from: :pending, to: :completed
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      hash = units.first.to_h

      expect(hash[:type]).to eq(:state_machine)
      expect(hash[:identifier]).to eq('Order::aasm')
      expect(hash[:source_code]).to include('# State machine (aasm) for Order')
      expect(hash[:source_hash]).to be_a(String)
      expect(hash[:extracted_at]).to be_a(String)

      # JSON round-trip
      json = JSON.generate(hash)
      parsed = JSON.parse(json)
      expect(parsed['type']).to eq('state_machine')
      expect(parsed['identifier']).to eq('Order::aasm')
    end
  end
end
