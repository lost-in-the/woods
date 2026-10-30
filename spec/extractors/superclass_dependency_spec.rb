# frozen_string_literal: true

require 'spec_helper'
require 'delegate'
require 'active_support/core_ext/string/inflections'
require 'woods'
require 'woods/extractor'
require 'woods/extractors/superclass_dependency'

RSpec.describe Woods::Extractors::SuperclassDependency do
  include_context 'extractor setup'

  subject(:resolver) { described_class.new }

  before do
    stub_const('InheritanceFixture', Module.new)
    stub_const('ActiveRecord::Base', Class.new do
      class << self
        attr_writer :abstract_class

        def abstract_class?
          @abstract_class == true
        end
      end
    end)
    stub_const('ActiveJob::Base', Class.new)
  end

  def declare(relative, source)
    path = create_file(relative, source)
    load path
    path
  end

  it 'emits nothing for a framework parent' do
    declare('app/models/inheritance_fixture/user.rb', "class InheritanceFixture::User < ActiveRecord::Base\nend\n")

    expect(resolver.call(InheritanceFixture::User)).to be_nil
  end

  it 'types an STI parent as the model unit its extractor publishes' do
    declare('app/models/inheritance_fixture/user.rb', "class InheritanceFixture::User < ActiveRecord::Base\nend\n")
    declare('app/models/inheritance_fixture/admin.rb', "class InheritanceFixture::Admin < InheritanceFixture::User\nend\n")

    expect(resolver.call(InheritanceFixture::Admin))
      .to eq(type: :model, target: 'InheritanceFixture::User', via: :inheritance)
  end

  it 'emits nothing for an abstract Active Record base, which the model extractor never publishes' do
    declare('app/models/inheritance_fixture/application_record.rb', <<~RUBY)
      class InheritanceFixture::ApplicationRecord < ActiveRecord::Base
        self.abstract_class = true
      end
    RUBY
    declare('app/models/inheritance_fixture/post.rb',
            "class InheritanceFixture::Post < InheritanceFixture::ApplicationRecord\nend\n")

    expect(resolver.call(InheritanceFixture::Post)).to be_nil
  end

  it 'types a Phlex component parent as a component' do
    stub_const('Phlex::HTML', Class.new)
    declare('app/views/components/inheritance_fixture/button.rb', "class InheritanceFixture::Button < Phlex::HTML\nend\n")
    declare('app/views/components/inheritance_fixture/copy_button.rb',
            "class InheritanceFixture::CopyButton < InheritanceFixture::Button\nend\n")

    expect(resolver.call(InheritanceFixture::CopyButton))
      .to eq(type: :component, target: 'InheritanceFixture::Button', via: :inheritance)
  end

  it 'types a ViewComponent parent as a view component and a preview parent as nothing' do
    stub_const('ViewComponent::Base', Class.new)
    stub_const('ViewComponent::Preview', Class.new)
    declare('app/components/inheritance_fixture/card.rb', "class InheritanceFixture::Card < ViewComponent::Base\nend\n")
    declare('app/components/inheritance_fixture/wide_card.rb',
            "class InheritanceFixture::WideCard < InheritanceFixture::Card\nend\n")
    declare('app/components/inheritance_fixture/card_preview.rb',
            "class InheritanceFixture::CardPreview < ViewComponent::Preview\nend\n")
    declare('app/components/inheritance_fixture/wide_card_preview.rb',
            "class InheritanceFixture::WideCardPreview < InheritanceFixture::CardPreview\nend\n")

    expect(resolver.call(InheritanceFixture::WideCard))
      .to eq(type: :view_component, target: 'InheritanceFixture::Card', via: :inheritance)
    expect(resolver.call(InheritanceFixture::WideCardPreview)).to be_nil
  end

  it 'types an application job parent as a job and ActiveJob::Base as nothing' do
    declare('app/jobs/inheritance_fixture/application_job.rb',
            "class InheritanceFixture::ApplicationJob < ActiveJob::Base\nend\n")
    declare('app/jobs/inheritance_fixture/notify_job.rb',
            "class InheritanceFixture::NotifyJob < InheritanceFixture::ApplicationJob\nend\n")

    expect(resolver.call(InheritanceFixture::NotifyJob))
      .to eq(type: :job, target: 'InheritanceFixture::ApplicationJob', via: :inheritance)
    expect(resolver.call(InheritanceFixture::ApplicationJob)).to be_nil
  end

  it 'types a parent under a service directory as a service' do
    declare('app/services/inheritance_fixture/application_service.rb',
            "class InheritanceFixture::ApplicationService\nend\n")
    declare('app/services/inheritance_fixture/checkout_service.rb',
            "class InheritanceFixture::CheckoutService < InheritanceFixture::ApplicationService\nend\n")

    expect(resolver.call(InheritanceFixture::CheckoutService))
      .to eq(type: :service, target: 'InheritanceFixture::ApplicationService', via: :inheritance)
  end

  it 'types a policy parent as a policy, never as the Pundit twin' do
    declare('app/policies/inheritance_fixture/application_policy.rb',
            "class InheritanceFixture::ApplicationPolicy\nend\n")
    declare('app/policies/inheritance_fixture/post_policy.rb',
            "class InheritanceFixture::PostPolicy < InheritanceFixture::ApplicationPolicy\nend\n")

    expect(resolver.call(InheritanceFixture::PostPolicy))
      .to eq(type: :policy, target: 'InheritanceFixture::ApplicationPolicy', via: :inheritance)
  end

  it 'types a plain class under app/models and unclaimed Ruby as a poro' do
    declare('app/models/inheritance_fixture/application_form.rb', "class InheritanceFixture::ApplicationForm\nend\n")
    declare('app/forms/inheritance_fixture/signup_form.rb',
            "class InheritanceFixture::SignupForm < InheritanceFixture::ApplicationForm\nend\n")
    declare('app/forms/inheritance_fixture/short_signup_form.rb',
            "class InheritanceFixture::ShortSignupForm < InheritanceFixture::SignupForm\nend\n")

    expect(resolver.call(InheritanceFixture::SignupForm))
      .to eq(type: :poro, target: 'InheritanceFixture::ApplicationForm', via: :inheritance)
    expect(resolver.call(InheritanceFixture::ShortSignupForm))
      .to eq(type: :poro, target: 'InheritanceFixture::SignupForm', via: :inheritance)
  end

  it 'types a parent under lib as a lib unit' do
    declare('lib/inheritance_fixture/base_client.rb', "class InheritanceFixture::BaseClient\nend\n")
    declare('lib/inheritance_fixture/ledger_client.rb',
            "class InheritanceFixture::LedgerClient < InheritanceFixture::BaseClient\nend\n")

    expect(resolver.call(InheritanceFixture::LedgerClient))
      .to eq(type: :lib, target: 'InheritanceFixture::BaseClient', via: :inheritance)
  end

  it 'types a delegator parent under app/managers as a manager' do
    declare('app/managers/inheritance_fixture/base_manager.rb',
            "class InheritanceFixture::BaseManager < SimpleDelegator\nend\n")
    declare('app/managers/inheritance_fixture/order_manager.rb',
            "class InheritanceFixture::OrderManager < InheritanceFixture::BaseManager\nend\n")

    expect(resolver.call(InheritanceFixture::OrderManager))
      .to eq(type: :manager, target: 'InheritanceFixture::BaseManager', via: :inheritance)
  end

  it 'types a graphql-ruby parent by the base it descends from' do
    stub_const('GraphQL::Schema', Module.new)
    stub_const('GraphQL::Schema::Object', Class.new)
    stub_const('GraphQL::Schema::Resolver', Class.new)
    stub_const('GraphQL::Schema::Mutation', Class.new(GraphQL::Schema::Resolver))
    declare('app/graphql/inheritance_fixture/base_object.rb',
            "class InheritanceFixture::BaseObject < GraphQL::Schema::Object\nend\n")
    declare('app/graphql/inheritance_fixture/post_type.rb',
            "class InheritanceFixture::PostType < InheritanceFixture::BaseObject\nend\n")
    declare('app/graphql/inheritance_fixture/base_mutation.rb',
            "class InheritanceFixture::BaseMutation < GraphQL::Schema::Mutation\nend\n")
    declare('app/graphql/inheritance_fixture/create_post.rb',
            "class InheritanceFixture::CreatePost < InheritanceFixture::BaseMutation\nend\n")

    expect(resolver.call(InheritanceFixture::PostType))
      .to eq(type: :graphql_type, target: 'InheritanceFixture::BaseObject', via: :inheritance)
    expect(resolver.call(InheritanceFixture::CreatePost))
      .to eq(type: :graphql_mutation, target: 'InheritanceFixture::BaseMutation', via: :inheritance)
  end

  describe 'a declared identifier' do
    it 'resolves the loaded class the file owns and reads its runtime parent' do
      declare('app/services/inheritance_fixture/application_service.rb',
              "class InheritanceFixture::ApplicationService\nend\n")
      path = declare('app/services/inheritance_fixture/checkout_service.rb',
                     "class InheritanceFixture::CheckoutService < InheritanceFixture::ApplicationService\nend\n")

      expect(resolver.call('InheritanceFixture::CheckoutService', file_path: path))
        .to eq(type: :service, target: 'InheritanceFixture::ApplicationService', via: :inheritance)
    end

    it 'emits nothing for a class that is not loaded' do
      path = create_file('app/services/inheritance_fixture/unloaded_service.rb',
                         "class InheritanceFixture::UnloadedService < InheritanceFixture::ApplicationService\nend\n")

      expect(resolver.call('InheritanceFixture::UnloadedService', file_path: path)).to be_nil
    end

    it 'never lends a same-named class from another file' do
      declare('app/services/inheritance_fixture/application_service.rb',
              "class InheritanceFixture::ApplicationService\nend\n")
      declare('app/services/inheritance_fixture/checkout_service.rb',
              "class InheritanceFixture::CheckoutService < InheritanceFixture::ApplicationService\nend\n")
      other = create_file('lib/vendored/checkout_service.rb',
                          "class InheritanceFixture::CheckoutService < InheritanceFixture::ApplicationService\nend\n")

      expect(resolver.call('InheritanceFixture::CheckoutService', file_path: other)).to be_nil
    end

    it 'emits nothing for a test double or any value that is not a class' do
      expect(resolver.call(double('Model', name: 'User'))).to be_nil
      expect(resolver.call(nil)).to be_nil
    end
  end
end
