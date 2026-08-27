# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/source_nesting'

RSpec.describe Woods::Extractors::SourceNesting do
  # Create a test class that includes the module so we can call its methods.
  let(:test_class) do
    Class.new do
      include Woods::Extractors::SourceNesting
    end
  end

  subject(:scanner) { test_class.new }

  # ── #qualified_first_class_name ──────────────────────────────────────

  describe '#qualified_first_class_name' do
    it 'returns the bare name for a top-level class' do
      source = <<~RUBY
        class Payment
          def call; end
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to eq('Payment')
    end

    it 'qualifies a class nested inside a module' do
      source = <<~RUBY
        module Billing
          class Payment
            def call; end
          end
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to eq('Billing::Payment')
    end

    it 'qualifies a class nested inside multiple modules' do
      source = <<~RUBY
        module Billing
          module Payments
            class Refund
            end
          end
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to eq('Billing::Payments::Refund')
    end

    it 'preserves compact-form segments for a top-level declaration' do
      source = <<~RUBY
        class Billing::Payment
          def call; end
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to eq('Billing::Payment')
    end

    it 'joins compact-form segments with enclosing modules' do
      source = <<~RUBY
        module Billing
          class Payments::Refund
          end
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to eq('Billing::Payments::Refund')
    end

    it 'does not include sibling modules that closed before the class opened' do
      source = <<~RUBY
        module Billing
          module Constants
            FEE = 1
          end

          class Payment
          end
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to eq('Billing::Payment')
    end

    it 'is not affected by modules nested after the first class' do
      source = <<~RUBY
        class Invoice
          module Formatting
            def self.currency; end
          end

          def total; end
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to eq('Invoice')
    end

    it 'returns a self-terminated one-liner class as the first class' do
      source = <<~RUBY
        module Billing
          class PaymentError < StandardError; end
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to eq('Billing::PaymentError')
    end

    it 'does not count a self-terminated module as enclosing what follows' do
      source = <<~RUBY
        module Sentinel; end

        class Payment
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to eq('Payment')
    end

    it 'tracks anonymous blocks so their ends do not pop enclosing modules' do
      source = <<~RUBY
        module Billing
          included do
            scope :recent, -> { order(created_at: :desc) }
          end

          class Payment
          end
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to eq('Billing::Payment')
    end

    it 'tracks method definitions so their ends do not pop enclosing modules' do
      source = <<~RUBY
        module Billing
          def self.fee
            1
          end

          class Payment
          end
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to eq('Billing::Payment')
    end

    it 'ignores comment lines mentioning class' do
      source = <<~RUBY
        # class Bogus
        module Billing
          class Payment
          end
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to eq('Billing::Payment')
    end

    it 'pops a block whose `end` is chained (`end.freeze`), not left dangling' do
      # An exact `stripped == 'end'` check misses `end.freeze`, so the `do`
      # block's frame was never popped and the enclosing module's own `end`
      # popped that stale frame instead of the module — leaving `Helpers`
      # open on the stack for everything that followed.
      source = <<~RUBY
        module Helpers
          LIST = %w[a b].map do |x|
            x
          end.freeze
        end

        module Mutations
          class CreateUser
          end
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to eq('Mutations::CreateUser')
    end

    it 'pops a block whose `end` is followed by a closing delimiter (`end)`)' do
      source = <<~RUBY
        module Helpers
          result = begin
            1
          end)
        end

        class Payment
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to eq('Payment')
    end

    it 'returns nil when the source has no class declaration' do
      source = <<~RUBY
        module Billing
          FEE = 1
        end
      RUBY

      expect(scanner.qualified_first_class_name(source)).to be_nil
    end

    it 'returns nil for empty source' do
      expect(scanner.qualified_first_class_name('')).to be_nil
    end
  end

  # ── #qualified_outer_module_name ─────────────────────────────────────

  describe '#qualified_outer_module_name' do
    it 'returns the module name for a simple module file' do
      source = <<~RUBY
        module Trackable
          def track!; end
        end
      RUBY

      expect(scanner.qualified_outer_module_name(source)).to eq('Trackable')
    end

    it 'joins a namespace wrapper chain' do
      source = <<~RUBY
        module Gateway
          module Stripe
            module Refundable
              def refund!; end
            end
          end
        end
      RUBY

      expect(scanner.qualified_outer_module_name(source)).to eq('Gateway::Stripe::Refundable')
    end

    it 'preserves compact-form segments' do
      source = <<~RUBY
        module Billing::Trackable
          def track!; end
        end
      RUBY

      expect(scanner.qualified_outer_module_name(source)).to eq('Billing::Trackable')
    end

    it 'never descends into a ClassMethods inner module' do
      source = <<~RUBY
        module Trackable
          module ClassMethods
            def tracked; end
          end
        end
      RUBY

      expect(scanner.qualified_outer_module_name(source)).to eq('Trackable')
    end

    it 'never descends into an InstanceMethods inner module' do
      source = <<~RUBY
        module Trackable
          module InstanceMethods
            def track!; end
          end
        end
      RUBY

      expect(scanner.qualified_outer_module_name(source)).to eq('Trackable')
    end

    it 'stops the chain at body content' do
      source = <<~RUBY
        module Trackable
          extend ActiveSupport::Concern

          module Validators
            def validate!; end
          end
        end
      RUBY

      expect(scanner.qualified_outer_module_name(source)).to eq('Trackable')
    end

    it 'skips prelude lines before the first module' do
      source = <<~RUBY
        require 'digest'

        module Trackable
          def track!; end
        end
      RUBY

      expect(scanner.qualified_outer_module_name(source)).to eq('Trackable')
    end

    it 'stops the chain at a self-terminated inner module' do
      source = <<~RUBY
        module JsonApi
          module Errors; end

          module Utils
            def self.helper; end
          end
        end
      RUBY

      expect(scanner.qualified_outer_module_name(source)).to eq('JsonApi')
    end

    it 'returns nil when the source opens no module' do
      source = <<~RUBY
        class Payment
        end
      RUBY

      expect(scanner.qualified_outer_module_name(source)).to be_nil
    end

    it 'returns nil for empty source' do
      expect(scanner.qualified_outer_module_name('')).to be_nil
    end
  end

  # ── #block_opener? ───────────────────────────────────────────────────

  describe '#block_opener?' do
    it 'counts trailing do blocks as openers' do
      expect(scanner.block_opener?('items.each do |item|')).to be true
    end

    it 'counts def as an opener' do
      expect(scanner.block_opener?('def call')).to be true
    end

    it 'counts line-leading if as an opener' do
      expect(scanner.block_opener?('if ready?')).to be true
    end

    it 'does not count a trailing if modifier as an opener' do
      expect(scanner.block_opener?('return if done?')).to be false
    end

    it 'does not count a self-terminated definition as an opener' do
      expect(scanner.block_opener?('def call; end')).to be false
    end
  end
end
