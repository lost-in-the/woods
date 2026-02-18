# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'codebase_index/extractors/policy_extractor'

RSpec.describe CodebaseIndex::Extractors::PolicyExtractor, 'fixture specs' do
  include_context 'extractor setup'

  # ── Pundit-Style Policy ───────────────────────────────────────────────

  describe 'Pundit-style policy with standard methods' do
    it 'detects Pundit pattern and extracts authorization methods' do
      path = create_file('app/policies/article_policy.rb', <<~RUBY)
        class ArticlePolicy < ApplicationPolicy
          def index?
            true
          end

          def show?
            true
          end

          def create?
            user.admin? || user.editor?
          end

          def update?
            user.admin? || record.author == user
          end

          def destroy?
            user.admin?
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)

      expect(unit).not_to be_nil
      expect(unit.type).to eq(:policy)
      expect(unit.identifier).to eq('ArticlePolicy')
      expect(unit.metadata[:is_pundit]).to be true
      expect(unit.metadata[:decision_methods]).to include('index?', 'show?', 'create?', 'update?', 'destroy?')
      expect(unit.metadata[:evaluated_models]).to include('Article')
    end
  end

  # ── Domain Policy with Custom Decision Methods ────────────────────────

  describe 'domain policy with custom decision methods' do
    it 'extracts eligible?, allowed?, and custom question methods' do
      path = create_file('app/policies/subscription_upgrade_policy.rb', <<~RUBY)
        class SubscriptionUpgradePolicy
          def initialize(account, target_plan)
            @account = account
            @target_plan = target_plan
          end

          def eligible?
            @account.active? && !@account.suspended?
          end

          def allowed?
            eligible? && meets_requirements?
          end

          def can_upgrade?
            allowed? && @target_plan.tier > @account.current_plan.tier
          end

          def should_notify?
            @account.preferences.notify_on_upgrade?
          end

          private

          def meets_requirements?
            @account.tenure_months > 3
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)

      expect(unit).not_to be_nil
      expect(unit.metadata[:is_pundit]).to be false
      expect(unit.metadata[:decision_methods]).to include('eligible?', 'allowed?', 'can_upgrade?', 'should_notify?')
      expect(unit.metadata[:decision_methods]).not_to include('meets_requirements?')
      expect(unit.metadata[:evaluated_models]).to include('SubscriptionUpgrade')
    end
  end

  # ── Edge: Policy with No Decision Methods ─────────────────────────────

  describe 'policy with no decision methods' do
    it 'extracts policy with empty decision methods list' do
      path = create_file('app/policies/base_policy.rb', <<~RUBY)
        class BasePolicy
          def initialize(user, record)
            @user = user
            @record = record
          end

          def scope
            record.class.all
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)

      expect(unit).not_to be_nil
      expect(unit.metadata[:decision_methods]).to be_empty
    end
  end

  # ── Edge: Deeply Nested Namespace ─────────────────────────────────────

  describe 'deeply nested namespace' do
    it 'extracts policy with multi-level namespace' do
      path = create_file('app/policies/billing/subscriptions/renewal_policy.rb', <<~RUBY)
        class Billing::Subscriptions::RenewalPolicy
          def initialize(subscription)
            @subscription = subscription
          end

          def eligible?
            @subscription.active? && @subscription.renewable?
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)

      expect(unit).not_to be_nil
      expect(unit.identifier).to eq('Billing::Subscriptions::RenewalPolicy')
      expect(unit.namespace).to eq('Billing::Subscriptions')
      expect(unit.metadata[:decision_methods]).to include('eligible?')
    end
  end

  # ── Policy with Custom Errors ─────────────────────────────────────────

  describe 'policy with custom error classes' do
    it 'extracts custom error class names' do
      path = create_file('app/policies/transfer_policy.rb', <<~RUBY)
        class TransferPolicy
          class IneligibleError < StandardError; end
          class InsufficientFundsError < StandardError; end

          def initialize(account)
            @account = account
          end

          def allowed?
            @account.balance > 0
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)

      expect(unit.metadata[:custom_errors]).to include('IneligibleError', 'InsufficientFundsError')
    end
  end

  # ── Policy with Class Methods ─────────────────────────────────────────

  describe 'policy with class methods' do
    it 'extracts class methods' do
      path = create_file('app/policies/access_policy.rb', <<~RUBY)
        class AccessPolicy
          def self.default_scope(user)
            user.admin? ? :all : :own
          end

          def initialize(user, resource)
            @user = user
            @resource = resource
          end

          def can_access?
            @user.active?
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)

      expect(unit.metadata[:class_methods]).to include('default_scope')
      expect(unit.metadata[:decision_methods]).to include('can_access?')
    end
  end

  # ── Policy Dependencies ───────────────────────────────────────────────

  describe 'policy with service and job dependencies' do
    it 'extracts all dependency types' do
      path = create_file('app/policies/approval_policy.rb', <<~RUBY)
        class ApprovalPolicy
          def initialize(request)
            @request = request
          end

          def eligible?
            ComplianceService.check(@request) &&
              !AuditService.flagged?(@request.id)
          end
        end
      RUBY

      unit = described_class.new.extract_policy_file(path)

      service_deps = unit.dependencies.select { |d| d[:type] == :service }
      targets = service_deps.map { |d| d[:target] }
      expect(targets).to include('ComplianceService', 'AuditService')
    end
  end
end
