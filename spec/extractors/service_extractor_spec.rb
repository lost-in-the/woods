# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/extractors/service_extractor'

RSpec.describe CodebaseIndex::Extractors::ServiceExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it_behaves_like 'handles missing directories'
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers files in app/services/' do
      create_file('app/services/checkout_service.rb', <<~RUBY)
        class CheckoutService
          def call(order)
            order.process!
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('CheckoutService')
      expect(units.first.type).to eq(:service)
    end

    it 'discovers files in app/interactors/' do
      create_file('app/interactors/create_order.rb', <<~RUBY)
        class CreateOrder
          include Interactor

          def call
            context.order = Order.create!(context.params)
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('CreateOrder')
    end

    it 'discovers files in app/operations/' do
      create_file('app/operations/import_data.rb', <<~RUBY)
        class ImportData
          def execute(file)
            CSV.parse(file)
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('ImportData')
    end

    it 'discovers files in app/commands/' do
      create_file('app/commands/send_invoice.rb', <<~RUBY)
        class SendInvoice
          def call(invoice)
            InvoiceMailer.send_invoice(invoice).deliver_later
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('SendInvoice')
    end

    it 'discovers files in app/use_cases/' do
      create_file('app/use_cases/register_user.rb', <<~RUBY)
        class RegisterUser
          def perform(params)
            User.create!(params)
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('RegisterUser')
    end

    it 'skips module-only files' do
      create_file('app/services/service_helpers.rb', <<~RUBY)
        module ServiceHelpers
          def log(msg)
            Rails.logger.info(msg)
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units).to be_empty
    end
  end

  # ── extract_service_file ─────────────────────────────────────────────

  describe '#extract_service_file' do
    it 'extracts service metadata' do
      path = create_file('app/services/checkout_service.rb', <<~RUBY)
        class CheckoutService
          def initialize(order, gateway:)
            @order = order
            @gateway = gateway
          end

          def call
            charge = @gateway.charge(@order.total)
            @order.update!(charged: true) if charge.success?
          end

          private

          def validate_order
            @order.valid?
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)

      expect(unit).not_to be_nil
      expect(unit.type).to eq(:service)
      expect(unit.identifier).to eq('CheckoutService')
      expect(unit.metadata[:entry_points]).to include('call')
      expect(unit.metadata[:is_callable]).to be true
      expect(unit.metadata[:public_methods]).to include('initialize', 'call')
      expect(unit.metadata[:public_methods]).not_to include('validate_order')
    end

    it 'detects multiple entry points' do
      path = create_file('app/services/multi_service.rb', <<~RUBY)
        class MultiService
          def call
            execute
          end

          def execute
            run
          end

          def run
            process
          end

          def process
            true
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.metadata[:entry_points]).to include('call', 'execute', 'run', 'process')
    end

    it 'detects interactor pattern' do
      path = create_file('app/interactors/create_order.rb', <<~RUBY)
        class CreateOrder
          include Interactor

          def call
            context.order = Order.create!(context.params)
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.metadata[:is_interactor]).to be true
    end

    it 'detects Dry::Monads usage' do
      path = create_file('app/services/validate_payment.rb', <<~RUBY)
        class ValidatePayment
          include Dry::Monads[:result]

          def call(payment)
            return Failure(:invalid) unless payment.valid?

            Success(payment)
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.metadata[:uses_dry_monads]).to be true
      expect(unit.metadata[:return_type]).to eq(:dry_monad)
    end

    it 'extracts initialize parameters' do
      path = create_file('app/services/notify_service.rb', <<~RUBY)
        class NotifyService
          def initialize(user, message:, urgent: false)
            @user = user
            @message = message
            @urgent = urgent
          end

          def call
            send_notification
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      params = unit.metadata[:initialize_params]
      expect(params.size).to eq(3)
      expect(params.first[:name]).to eq('user')
    end

    it 'extracts custom error classes' do
      path = create_file('app/services/payment_service.rb', <<~RUBY)
        class PaymentService
          class PaymentError < StandardError; end
          class InsufficientFundsError < PaymentError; end

          def call(amount)
            raise InsufficientFundsError if amount > balance
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.metadata[:custom_errors]).to include('PaymentError', 'InsufficientFundsError')
    end

    it 'extracts rescue handlers' do
      path = create_file('app/services/import_service.rb', <<~RUBY)
        class ImportService
          def call(file)
            CSV.parse(file)
          rescue CSV::MalformedCSVError
            nil
          rescue ActiveRecord::RecordInvalid
            nil
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.metadata[:rescues]).to include('CSV::MalformedCSVError', 'ActiveRecord::RecordInvalid')
    end

    it 'extracts injected dependencies' do
      path = create_file('app/services/order_service.rb', <<~RUBY)
        class OrderService
          attr_reader :payment_service, :notification_client

          def initialize(payment_service:, notification_client:)
            @payment_service = payment_service
            @notification_client = notification_client
          end

          def call
            payment_service.charge
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.metadata[:injected_dependencies]).to include('payment_service', 'notification_client')
    end

    it 'computes complexity and loc' do
      path = create_file('app/services/complex_service.rb', <<~RUBY)
        class ComplexService
          def call(data)
            if data.valid?
              unless data.processed?
                data.items.each do |item|
                  if item.active? && item.ready?
                    process(item)
                  end
                end
              end
            end
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.metadata[:complexity]).to be > 1
      expect(unit.metadata[:loc]).to be > 0
      expect(unit.metadata[:method_count]).to be >= 1
    end

    it 'annotates source with header' do
      path = create_file('app/services/checkout_service.rb', <<~RUBY)
        class CheckoutService
          def call
            true
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.source_code).to include('Service: CheckoutService')
      expect(unit.source_code).to include('Entry Points:')
    end

    it 'returns nil for module-only files' do
      path = create_file('app/services/helpers.rb', <<~RUBY)
        module Helpers
          def log(msg)
            puts msg
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit).to be_nil
    end

    it 'handles read errors gracefully' do
      unit = described_class.new.extract_service_file('/nonexistent/path.rb')
      expect(unit).to be_nil
    end
  end

  # ── Namespaced Classes ───────────────────────────────────────────────

  describe 'namespaced classes' do
    it 'extracts namespace from namespaced class' do
      create_file('app/services/payments/stripe_service.rb', <<~RUBY)
        class Payments::StripeService
          def call(amount)
            Stripe::Charge.create(amount: amount)
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Payments::StripeService')
      expect(units.first.namespace).to eq('Payments')
    end

    it 'handles deeply nested namespaces' do
      create_file('app/services/billing/payments/refund_service.rb', <<~RUBY)
        class Billing::Payments::RefundService
          def call(order)
            order.refund!
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.first.identifier).to eq('Billing::Payments::RefundService')
      expect(units.first.namespace).to eq('Billing::Payments')
    end
  end

  # ── Service Type Inference ───────────────────────────────────────────

  describe 'infer_service_type' do
    it 'infers :service for app/services/' do
      path = create_file('app/services/foo.rb', <<~RUBY)
        class Foo
          def call; end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.metadata[:service_type]).to eq(:service)
    end

    it 'infers :interactor for app/interactors/' do
      path = create_file('app/interactors/foo.rb', <<~RUBY)
        class Foo
          def call; end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.metadata[:service_type]).to eq(:interactor)
    end

    it 'infers :operation for app/operations/' do
      path = create_file('app/operations/foo.rb', <<~RUBY)
        class Foo
          def call; end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.metadata[:service_type]).to eq(:operation)
    end

    it 'infers :command for app/commands/' do
      path = create_file('app/commands/foo.rb', <<~RUBY)
        class Foo
          def call; end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.metadata[:service_type]).to eq(:command)
    end

    it 'infers :use_case for app/use_cases/' do
      path = create_file('app/use_cases/foo.rb', <<~RUBY)
        class Foo
          def call; end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.metadata[:service_type]).to eq(:use_case)
    end
  end

  # ── Entry Point Detection ───────────────────────────────────────────

  describe 'detect_entry_points' do
    it 'detects self.call as entry point' do
      path = create_file('app/services/static_service.rb', <<~RUBY)
        class StaticService
          def self.call(args)
            new(args).process
          end

          def process
            true
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.metadata[:entry_points]).to include('call')
      expect(unit.metadata[:entry_points]).to include('process')
    end

    it 'returns unknown when no entry points found' do
      path = create_file('app/services/plain_service.rb', <<~RUBY)
        class PlainService
          def do_work
            true
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      expect(unit.metadata[:entry_points]).to eq(['unknown'])
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependency extraction' do
    it_behaves_like 'all dependencies have :via key',
                    :extract_service_file,
                    'app/services/checkout_service.rb',
                    <<~RUBY
                      class CheckoutService
                        def call
                          PaymentService.charge
                          NotificationJob.perform_later
                        end
                      end
                    RUBY

    it 'detects interactor dependencies' do
      path = create_file('app/services/order_flow.rb', <<~RUBY)
        class OrderFlow
          def call
            CreateOrderInteractor.call(params)
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      interactor_deps = unit.dependencies.select { |d| d[:type] == :interactor }
      expect(interactor_deps.first[:target]).to eq('CreateOrderInteractor')
      expect(interactor_deps.first[:via]).to eq(:code_reference)
    end

    it 'detects API client dependencies' do
      path = create_file('app/services/sync_service.rb', <<~RUBY)
        class SyncService
          def call
            StripeClient.new.charge(100)
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      client_deps = unit.dependencies.select { |d| d[:type] == :api_client }
      expect(client_deps.first[:target]).to eq('StripeClient')
    end

    it 'detects HTTP library dependencies' do
      path = create_file('app/services/webhook_service.rb', <<~RUBY)
        class WebhookService
          def call(url, payload)
            Faraday.post(url, payload)
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      http_deps = unit.dependencies.select { |d| d[:target] == :http_api }
      expect(http_deps).not_to be_empty
    end

    it 'detects Redis dependencies' do
      path = create_file('app/services/cache_service.rb', <<~RUBY)
        class CacheService
          def call(key, value)
            Redis.current.set(key, value)
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      redis_deps = unit.dependencies.select { |d| d[:target] == :redis }
      expect(redis_deps).not_to be_empty
    end

    it 'detects service dependencies via shared scanner' do
      path = create_file('app/services/orchestrator_service.rb', <<~RUBY)
        class OrchestratorService
          def call
            PaymentService.call
            ShippingService.new.execute
          end
        end
      RUBY

      unit = described_class.new.extract_service_file(path)
      service_deps = unit.dependencies.select { |d| d[:type] == :service }
      targets = service_deps.map { |d| d[:target] }
      expect(targets).to include('PaymentService', 'ShippingService')
    end
  end
end
