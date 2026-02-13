# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'codebase_index/extractors/policy_extractor'

RSpec.describe CodebaseIndex::Extractors::PolicyExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it_behaves_like 'handles missing directories'
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers policy files in app/policies/' do
      create_file('app/policies/refund_policy.rb', <<~RUBY)
        class RefundPolicy
          def initialize(order)
            @order = order
          end

          def eligible?
            @order.total > 0
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('RefundPolicy')
      expect(units.first.type).to eq(:policy)
    end

    it 'discovers files in nested directories' do
      create_file('app/policies/billing/upgrade_policy.rb', <<~RUBY)
        class Billing::UpgradePolicy
          def initialize(account)
            @account = account
          end

          def eligible?
            @account.active?
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Billing::UpgradePolicy')
      expect(units.first.namespace).to eq('Billing')
    end

    it 'skips module-only files' do
      create_file('app/policies/policy_concern.rb', <<~RUBY)
        module PolicyConcern
          def log_decision(result)
            Rails.logger.info(result)
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units).to be_empty
    end
  end

  # ── extract_policy_file ──────────────────────────────────────────────

  describe '#extract_policy_file' do
    it 'extracts policy metadata' do
      path = create_file('app/policies/refund_policy.rb', <<~RUBY)
        class RefundPolicy
          def initialize(order)
            @order = order
          end

          def eligible?
            @order.completed? && within_window?
          end

          def allowed?
            eligible? && !@order.already_refunded?
          end

          private

          def within_window?
            @order.created_at > 30.days.ago
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)

      expect(unit).not_to be_nil
      expect(unit.type).to eq(:policy)
      expect(unit.identifier).to eq('RefundPolicy')
      expect(unit.metadata[:decision_methods]).to include('eligible?', 'allowed?')
      expect(unit.metadata[:decision_methods]).not_to include('within_window?')
      expect(unit.metadata[:evaluated_models]).to include('Order')
      expect(unit.metadata[:public_methods]).to include('initialize', 'eligible?', 'allowed?')
      expect(unit.metadata[:public_methods]).not_to include('within_window?')
    end

    it 'detects Pundit-style policies' do
      path = create_file('app/policies/post_policy.rb', <<~RUBY)
        class PostPolicy < ApplicationPolicy
          def update?
            user.admin? || record.author == user
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)
      expect(unit.metadata[:is_pundit]).to be true
    end

    it 'annotates source with header' do
      path = create_file('app/policies/refund_policy.rb', <<~RUBY)
        class RefundPolicy
          def initialize(order)
            @order = order
          end

          def eligible?
            true
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)
      expect(unit.source_code).to include('Policy: RefundPolicy')
      expect(unit.source_code).to include('Evaluates:')
      expect(unit.source_code).to include('Decisions:')
    end

    it 'returns nil for non-policy files when called directly' do
      path = create_file('app/policies/utility.rb', <<~RUBY)
        module PolicyHelpers
          def log(msg)
            puts msg
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)
      expect(unit).to be_nil
    end

    it 'handles read errors gracefully' do
      unit = described_class.new.extract_policy_file('/nonexistent/path.rb')
      expect(unit).to be_nil
    end

    it 'infers evaluated model from class name' do
      path = create_file('app/policies/subscription_policy.rb', <<~RUBY)
        class SubscriptionPolicy
          def can_cancel?
            true
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)
      expect(unit.metadata[:evaluated_models]).to include('Subscription')
    end

    it 'detects multiple decision method patterns' do
      path = create_file('app/policies/feature_policy.rb', <<~RUBY)
        class FeaturePolicy
          def initialize(user)
            @user = user
          end

          def can_access?
            @user.premium?
          end

          def qualifies?
            @user.tenure > 30
          end

          def meets_requirements?
            can_access? && qualifies?
          end

          def should_show?
            true
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)
      expect(unit.metadata[:decision_methods]).to include('can_access?', 'qualifies?', 'meets_requirements?', 'should_show?')
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependency extraction' do
    it_behaves_like 'all dependencies have :via key',
                    :extract_policy_file,
                    'app/policies/refund_policy.rb',
                    <<~RUBY
                      class RefundPolicy
                        def initialize(order)
                          @order = order
                        end

                        def eligible?
                          EligibilityService.call(@order)
                        end
                      end
                    RUBY

    it 'detects evaluated model as a policy_evaluation dependency' do
      path = create_file('app/policies/refund_policy.rb', <<~RUBY)
        class RefundPolicy
          def initialize(order)
            @order = order
          end

          def eligible?
            true
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)
      evaluation_deps = unit.dependencies.select { |d| d[:via] == :policy_evaluation }
      targets = evaluation_deps.map { |d| d[:target] }
      expect(targets).to include('Order')
    end

    it 'detects service dependencies' do
      path = create_file('app/policies/upgrade_policy.rb', <<~RUBY)
        class UpgradePolicy
          def initialize(account)
            @account = account
          end

          def eligible?
            BillingService.call(@account).active?
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)
      service_deps = unit.dependencies.select { |d| d[:type] == :service }
      expect(service_deps.first[:target]).to eq('BillingService')
      expect(service_deps.first[:via]).to eq(:code_reference)
    end
  end
end
