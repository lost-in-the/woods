# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'delegate'
require 'woods/extractors/manager_extractor'
require 'woods/extractors/pundit_extractor'
require 'woods/extractors/policy_extractor'

RSpec.describe 'Selected declaration runtime ancestry' do
  include_context 'extractor setup'

  before { stub_const('AncestryFixture', Module.new) }

  def declare(relative, body)
    path = create_file(relative, "module AncestryFixture\n#{body}\nend\n")
    load path
    path
  end

  %w[SimpleDelegator ::SimpleDelegator BaseManager].each do |parent|
    it "discovers the actual manager through #{parent}" do
      declare('app/managers/ancestry_fixture/base_manager.rb', 'class BaseManager < SimpleDelegator; end')
      path = declare('app/managers/ancestry_fixture/order_manager.rb', "class OrderManager < #{parent}; end")

      unit = Woods::Extractors::ManagerExtractor.new.extract_manager_file(path)

      expect(unit&.identifier).to eq('AncestryFixture::OrderManager')
      expect(unit.metadata[:delegation_type]).to eq(:simple_delegator)
    end
  end

  %w[ApplicationPolicy ::AncestryFixture::ApplicationPolicy BasePolicy].each do |parent|
    it "recognizes actual Pundit inheritance through #{parent} in both policy metadata types" do
      declare('app/policies/ancestry_fixture/application_policy.rb', 'class ApplicationPolicy; end')
      declare('app/policies/ancestry_fixture/base_policy.rb', 'class BasePolicy < ApplicationPolicy; end')
      path = declare('app/policies/ancestry_fixture/order_policy.rb', "class OrderPolicy < #{parent}; end")

      pundit = Woods::Extractors::PunditExtractor.new.extract_pundit_file(path)
      policy = Woods::Extractors::PolicyExtractor.new.extract_policy_file(path)

      expect(pundit&.identifier).to eq('AncestryFixture::OrderPolicy')
      expect(pundit.metadata[:inherits_application_policy]).to be(true)
      expect(policy.metadata[:is_pundit]).to be(true)
    end
  end

  it 'does not qualify unrelated loaded classes through examples in comments or sibling declarations' do
    manager = declare('app/managers/ancestry_fixture/plain_manager.rb', <<~RUBY)
      # Example: class Example < SimpleDelegator
      class HelperManager < SimpleDelegator; end
      class PlainManager; end
    RUBY
    policy = declare('app/policies/ancestry_fixture/plain_policy.rb', <<~RUBY)
      # Example: class Example < ApplicationPolicy
      class PlainPolicy; end
    RUBY

    expect(Woods::Extractors::ManagerExtractor.new.extract_manager_file(manager)).to be_nil
    expect(Woods::Extractors::PunditExtractor.new.extract_pundit_file(policy)).to be_nil
    expect(Woods::Extractors::PolicyExtractor.new.extract_policy_file(policy).metadata[:is_pundit]).to be(false)
  end

  it 'does not borrow ancestry from a same-named class owned by another source file' do
    declare('lib/original_manager.rb', 'class DuplicateManager < SimpleDelegator; end')
    declare('lib/original_policy.rb', 'class ApplicationPolicy; end; class DuplicatePolicy < ApplicationPolicy; end')
    manager = create_file('app/managers/ancestry_fixture/duplicate_manager.rb',
                          'class AncestryFixture::DuplicateManager < SimpleDelegator; end')
    policy = create_file('app/policies/ancestry_fixture/duplicate_policy.rb',
                         'class AncestryFixture::DuplicatePolicy < AncestryFixture::ApplicationPolicy; end')

    expect(Woods::Extractors::ManagerExtractor.new.extract_manager_file(manager)).to be_nil
    expect(Woods::Extractors::PunditExtractor.new.extract_pundit_file(policy)).to be_nil
    expect(Woods::Extractors::PolicyExtractor.new.extract_policy_file(policy).metadata[:is_pundit]).to be(false)
  end

  it 'does not trigger pending application class autoloads to establish ancestry' do
    dormant = create_file('lib/dormant_policy.rb', "raise 'unexpected autoload'")
    AncestryFixture.autoload(:DormantPolicy, dormant)
    path = create_file('app/policies/ancestry_fixture/dormant_policy.rb',
                       'class AncestryFixture::DormantPolicy < UnavailableBase; end')

    expect(Woods::Extractors::PunditExtractor.new.extract_pundit_file(path)).to be_nil
    expect(AncestryFixture.autoload?(:DormantPolicy)).to eq(dormant)
  end

  it 'does not use a constant alias as proof of the declared runtime identity' do
    declare('lib/original_manager.rb', 'class OriginalManager < SimpleDelegator; end')
    AncestryFixture.const_set(:AliasManager, AncestryFixture::OriginalManager)
    path = create_file('app/managers/ancestry_fixture/alias_manager.rb',
                       'class AncestryFixture::AliasManager < SimpleDelegator; end')

    expect(Woods::Extractors::ManagerExtractor.new.extract_manager_file(path)).to be_nil
  end

  it 'retains owned runtime ancestry when an unexecuted declaration has an unknown receiver' do
    path = declare('app/managers/ancestry_fixture/order_manager.rb', <<~RUBY)
      class OrderManager < SimpleDelegator; end
      if false
        class UnavailableNamespace::UnusedHelper; end
      end
    RUBY

    expect(Woods::Extractors::ManagerExtractor.new.extract_manager_file(path)&.identifier)
      .to eq('AncestryFixture::OrderManager')
  end

  it 'preserves generic policy emission when structural namespace evidence is unavailable' do
    path = create_file('app/policies/unavailable_namespace/plain_policy.rb',
                       'class UnavailableNamespace::PlainPolicy; end')

    policy = Woods::Extractors::PolicyExtractor.new.extract_policy_file(path)

    expect(policy&.identifier).to eq('UnavailableNamespace::PlainPolicy')
    expect(policy.metadata[:is_pundit]).to be(false)
  end
end
