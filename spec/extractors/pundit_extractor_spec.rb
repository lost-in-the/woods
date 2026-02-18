# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/extractors/pundit_extractor'

RSpec.describe CodebaseIndex::Extractors::PunditExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it_behaves_like 'handles missing directories'
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers Pundit policies in app/policies/' do
      create_file('app/policies/post_policy.rb', <<~RUBY)
        class PostPolicy < ApplicationPolicy
          def update?
            user.admin? || record.author == user
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('PostPolicy')
      expect(units.first.type).to eq(:pundit_policy)
    end

    it 'discovers nested Pundit policies' do
      create_file('app/policies/admin/user_policy.rb', <<~RUBY)
        class Admin::UserPolicy < ApplicationPolicy
          def index?
            user.admin?
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Admin::UserPolicy')
      expect(units.first.namespace).to eq('Admin')
    end

    it 'skips non-Pundit policy files' do
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
      expect(units).to be_empty
    end

    it 'detects Pundit policies via user/record pattern' do
      create_file('app/policies/comment_policy.rb', <<~RUBY)
        class CommentPolicy
          attr_reader :user, :record

          def initialize(user, record)
            @user = user
            @record = record
          end

          def create?
            user.present?
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
    end
  end

  # ── extract_pundit_file ────────────────────────────────────────────

  describe '#extract_pundit_file' do
    it 'extracts authorization actions' do
      path = create_file('app/policies/post_policy.rb', <<~RUBY)
        class PostPolicy < ApplicationPolicy
          def index?
            true
          end

          def show?
            true
          end

          def create?
            user.admin?
          end

          def update?
            user.admin? || record.author == user
          end

          def destroy?
            user.admin?
          end

          private

          def admin?
            user.admin?
          end
        end
      RUBY

      unit = described_class.new.extract_pundit_file(path)

      expect(unit).not_to be_nil
      expect(unit.metadata[:authorization_actions]).to include('index?', 'show?', 'create?', 'update?', 'destroy?')
      expect(unit.metadata[:authorization_actions]).not_to include('admin?')
    end

    it 'separates standard and custom actions' do
      path = create_file('app/policies/post_policy.rb', <<~RUBY)
        class PostPolicy < ApplicationPolicy
          def index?
            true
          end

          def publish?
            user.editor?
          end

          def archive?
            user.admin?
          end
        end
      RUBY

      unit = described_class.new.extract_pundit_file(path)
      expect(unit.metadata[:standard_actions]).to eq(['index?'])
      expect(unit.metadata[:custom_actions]).to include('publish?', 'archive?')
    end

    it 'infers model from class name' do
      path = create_file('app/policies/post_policy.rb', <<~RUBY)
        class PostPolicy < ApplicationPolicy
          def show?
            true
          end
        end
      RUBY

      unit = described_class.new.extract_pundit_file(path)
      expect(unit.metadata[:model]).to eq('Post')
    end

    it 'detects Scope inner class' do
      path = create_file('app/policies/post_policy.rb', <<~RUBY)
        class PostPolicy < ApplicationPolicy
          def index?
            true
          end

          class Scope < Scope
            def resolve
              if user.admin?
                scope.all
              else
                scope.where(published: true)
              end
            end
          end
        end
      RUBY

      unit = described_class.new.extract_pundit_file(path)
      expect(unit.metadata[:has_scope_class]).to be true
    end

    it 'excludes Scope class methods from authorization_actions' do
      path = create_file('app/policies/post_policy.rb', <<~RUBY)
        class PostPolicy < ApplicationPolicy
          def show?
            true
          end

          class Scope < Scope
            def resolve?
              true
            end
          end
        end
      RUBY

      unit = described_class.new.extract_pundit_file(path)
      expect(unit.metadata[:authorization_actions]).to include('show?')
      expect(unit.metadata[:authorization_actions]).not_to include('resolve?')
    end

    it 'detects ApplicationPolicy inheritance' do
      path = create_file('app/policies/post_policy.rb', <<~RUBY)
        class PostPolicy < ApplicationPolicy
          def show?
            true
          end
        end
      RUBY

      unit = described_class.new.extract_pundit_file(path)
      expect(unit.metadata[:inherits_application_policy]).to be true
    end

    it 'annotates source with header' do
      path = create_file('app/policies/post_policy.rb', <<~RUBY)
        class PostPolicy < ApplicationPolicy
          def show?
            true
          end
        end
      RUBY

      unit = described_class.new.extract_pundit_file(path)
      expect(unit.source_code).to include('Pundit Policy: PostPolicy')
      expect(unit.source_code).to include('Model: Post')
      expect(unit.source_code).to include('Actions:')
    end

    it 'returns nil for non-Pundit files' do
      path = create_file('app/policies/plain_policy.rb', <<~RUBY)
        class PlainPolicy
          def initialize(order)
            @order = order
          end

          def eligible?
            true
          end
        end
      RUBY

      unit = described_class.new.extract_pundit_file(path)
      expect(unit).to be_nil
    end

    it 'handles read errors gracefully' do
      unit = described_class.new.extract_pundit_file('/nonexistent/path.rb')
      expect(unit).to be_nil
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependency extraction' do
    it_behaves_like 'all dependencies have :via key',
                    :extract_pundit_file,
                    'app/policies/post_policy.rb',
                    <<~RUBY
                      class PostPolicy < ApplicationPolicy
                        def update?
                          AuthorizationService.check(user, record)
                        end
                      end
                    RUBY

    it 'links to model as authorization dependency' do
      path = create_file('app/policies/post_policy.rb', <<~RUBY)
        class PostPolicy < ApplicationPolicy
          def show?
            true
          end
        end
      RUBY

      unit = described_class.new.extract_pundit_file(path)
      auth_deps = unit.dependencies.select { |d| d[:via] == :authorization }
      expect(auth_deps.first[:target]).to eq('Post')
      expect(auth_deps.first[:type]).to eq(:model)
    end

    it 'detects service dependencies' do
      path = create_file('app/policies/post_policy.rb', <<~RUBY)
        class PostPolicy < ApplicationPolicy
          def update?
            AuthorizationService.check(user, record)
          end
        end
      RUBY

      unit = described_class.new.extract_pundit_file(path)
      service_deps = unit.dependencies.select { |d| d[:type] == :service }
      expect(service_deps.first[:target]).to eq('AuthorizationService')
    end
  end
end
