# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'codebase_index/extractors/manager_extractor'

RSpec.describe CodebaseIndex::Extractors::ManagerExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it_behaves_like 'handles missing directories'
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers manager files in app/managers/' do
      create_file('app/managers/order_manager.rb', <<~RUBY)
        class OrderManager < SimpleDelegator
          def total_with_tax
            total * 1.1
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('OrderManager')
      expect(units.first.type).to eq(:manager)
    end

    it 'discovers files in nested directories' do
      create_file('app/managers/billing/invoice_manager.rb', <<~RUBY)
        class Billing::InvoiceManager < SimpleDelegator
          def formatted_total
            "$\#{total}"
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Billing::InvoiceManager')
      expect(units.first.namespace).to eq('Billing')
    end

    it 'skips non-delegator files' do
      create_file('app/managers/helper_module.rb', <<~RUBY)
        module HelperModule
          def some_helper
            true
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units).to be_empty
    end
  end

  # ── extract_manager_file ─────────────────────────────────────────────

  describe '#extract_manager_file' do
    it 'extracts SimpleDelegator metadata' do
      path = create_file('app/managers/order_manager.rb', <<~RUBY)
        class OrderManager < SimpleDelegator
          def initialize(order)
            super(order)
            @tax_rate = 0.1
          end

          def total_with_tax
            total * (1 + @tax_rate)
          end

          def apply_discount(percent)
            self.total = total * (1 - percent / 100.0)
          end

          private

          def calculate_subtotal
            line_items.sum(&:price)
          end
        end
      RUBY

      unit = described_class.new.extract_manager_file(path)

      expect(unit).not_to be_nil
      expect(unit.type).to eq(:manager)
      expect(unit.identifier).to eq('OrderManager')
      expect(unit.metadata[:wrapped_model]).to eq('Order')
      expect(unit.metadata[:delegation_type]).to eq(:simple_delegator)
      expect(unit.metadata[:public_methods]).to include('initialize', 'total_with_tax', 'apply_discount')
      expect(unit.metadata[:public_methods]).not_to include('calculate_subtotal')
    end

    it 'extracts DelegateClass metadata' do
      path = create_file('app/managers/user_manager.rb', <<~RUBY)
        class UserManager < DelegateClass(User)
          def display_name
            "\#{first_name} \#{last_name}"
          end
        end
      RUBY

      unit = described_class.new.extract_manager_file(path)

      expect(unit).not_to be_nil
      expect(unit.metadata[:wrapped_model]).to eq('User')
      expect(unit.metadata[:delegation_type]).to eq(:delegate_class)
    end

    it 'annotates source with header' do
      path = create_file('app/managers/order_manager.rb', <<~RUBY)
        class OrderManager < SimpleDelegator
          def total_with_tax
            total * 1.1
          end
        end
      RUBY

      unit = described_class.new.extract_manager_file(path)
      expect(unit.source_code).to include('Manager: OrderManager')
      expect(unit.source_code).to include('Wraps: Order')
    end

    it 'returns nil for non-manager files' do
      path = create_file('app/managers/utility.rb', <<~RUBY)
        class Utility
          def self.format(data)
            data.to_json
          end
        end
      RUBY

      unit = described_class.new.extract_manager_file(path)
      expect(unit).to be_nil
    end

    it 'handles read errors gracefully' do
      unit = described_class.new.extract_manager_file('/nonexistent/path.rb')
      expect(unit).to be_nil
    end

    it 'returns nil wrapped_model for non-Manager class names' do
      path = create_file('app/managers/account_managing_products.rb', <<~RUBY)
        class AccountManagingProducts < SimpleDelegator
          def active_products
            products.select(&:active?)
          end
        end
      RUBY

      unit = described_class.new.extract_manager_file(path)
      expect(unit.metadata[:wrapped_model]).to be_nil
    end

    it 'infers wrapped model from class name when no explicit super' do
      path = create_file('app/managers/product_manager.rb', <<~RUBY)
        class ProductManager < SimpleDelegator
          def discounted_price
            price * 0.9
          end
        end
      RUBY

      unit = described_class.new.extract_manager_file(path)
      expect(unit.metadata[:wrapped_model]).to eq('Product')
    end

    it 'extracts delegated methods' do
      path = create_file('app/managers/account_manager.rb', <<~RUBY)
        class AccountManager < SimpleDelegator
          delegate :email, :phone, to: :contact_info

          def full_summary
            "\#{name} - \#{email}"
          end
        end
      RUBY

      unit = described_class.new.extract_manager_file(path)
      expect(unit.metadata[:delegated_methods]).to include('email', 'phone')
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependency extraction' do
    it_behaves_like 'all dependencies have :via key',
                    :extract_manager_file,
                    'app/managers/order_manager.rb',
                    <<~RUBY
                      class OrderManager < SimpleDelegator
                        def process
                          PaymentService.call(self)
                        end
                      end
                    RUBY

    it 'detects wrapped model as a delegation dependency' do
      path = create_file('app/managers/order_manager.rb', <<~RUBY)
        class OrderManager < SimpleDelegator
          def total_with_tax
            total * 1.1
          end
        end
      RUBY

      unit = described_class.new.extract_manager_file(path)
      delegation_deps = unit.dependencies.select { |d| d[:via] == :delegation }
      expect(delegation_deps.first[:target]).to eq('Order')
    end

    it 'detects service dependencies' do
      path = create_file('app/managers/order_manager.rb', <<~RUBY)
        class OrderManager < SimpleDelegator
          def checkout
            CheckoutService.call(self)
          end
        end
      RUBY

      unit = described_class.new.extract_manager_file(path)
      service_deps = unit.dependencies.select { |d| d[:type] == :service }
      expect(service_deps.first[:target]).to eq('CheckoutService')
      expect(service_deps.first[:via]).to eq(:code_reference)
    end

    it 'detects job dependencies' do
      path = create_file('app/managers/order_manager.rb', <<~RUBY)
        class OrderManager < SimpleDelegator
          def process_async
            OrderProcessingJob.perform_later(id)
          end
        end
      RUBY

      unit = described_class.new.extract_manager_file(path)
      job_deps = unit.dependencies.select { |d| d[:type] == :job }
      expect(job_deps.first[:target]).to eq('OrderProcessingJob')
    end
  end
end
