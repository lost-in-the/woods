# frozen_string_literal: true

require 'spec_helper'
require 'delegate'
require 'open3'
require 'rbconfig'
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

  # A parent class may define its own `self.name` (a display name, a
  # registry key). The edge names the constant, never that override (#965).
  it 'targets the constant name of a parent that overrides self.name' do
    declare('app/models/inheritance_fixture/named_base.rb',
            "class InheritanceFixture::NamedBase\n  def self.name = 'NamedBase'\nend\n")
    declare('app/forms/inheritance_fixture/named_form.rb',
            "class InheritanceFixture::NamedForm < InheritanceFixture::NamedBase\nend\n")

    expect(resolver.call(InheritanceFixture::NamedForm))
      .to eq(type: :poro, target: 'InheritanceFixture::NamedBase', via: :inheritance)
  end

  # Libraries are autoloaded, not eager-loaded, so during extraction a lib
  # class and its lib parent are still pending autoloads. The parent comes
  # from the declaration, resolved lexically against what the runtime
  # registers, and nothing is loaded to find it (#965).
  describe 'a library that is still a pending autoload' do
    let(:space) { File.join(tmp_dir, 'lib/inh_pending') }

    after do
      %i[InhPending InhPendingTop InhPendingBase].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
      end
    end

    def ledger(source)
      Object.autoload(:InhPending, space)
      create_file('lib/inh_pending/base_client.rb', "module InhPending\n  class BaseClient\n  end\nend\n")
      create_file('lib/inh_pending/ledger_client.rb', source)
    end

    it 'resolves a short parent inside its module block without loading either class' do
      path = ledger("module InhPending\n  class LedgerClient < BaseClient\n  end\nend\n")

      expect(resolver.call('InhPending::LedgerClient', file_path: path))
        .to eq(type: :lib, target: 'InhPending::BaseClient', via: :inheritance)
      expect(Object.autoload?(:InhPending)).to eq(space)
    end

    it 'resolves relative, compact and rooted spellings of the parent' do
      relative = ledger("module InhPending\n  class LedgerClient < InhPending::BaseClient\n  end\nend\n")
      expect(resolver.call('InhPending::LedgerClient', file_path: relative)).to include(target: 'InhPending::BaseClient')

      compact = ledger("class InhPending::LedgerClient < InhPending::BaseClient\nend\n")
      expect(resolver.call('InhPending::LedgerClient', file_path: compact)).to include(target: 'InhPending::BaseClient')

      rooted = ledger("module InhPending\n  class LedgerClient < ::InhPending::BaseClient\n  end\nend\n")
      expect(resolver.call('InhPending::LedgerClient', file_path: rooted)).to include(target: 'InhPending::BaseClient')
    end

    it 'resolves a top-level library parent' do
      base = create_file('lib/inh_pending_base.rb', "class InhPendingBase\nend\n")
      top = create_file('lib/inh_pending_top.rb', "class InhPendingTop < InhPendingBase\nend\n")
      Object.autoload(:InhPendingBase, base)
      Object.autoload(:InhPendingTop, top)

      expect(resolver.call('InhPendingTop', file_path: top))
        .to eq(type: :lib, target: 'InhPendingBase', via: :inheritance)
    end

    it 'emits nothing for a parent the runtime does not know or a framework parent' do
      missing = ledger("module InhPending\n  class LedgerClient < MissingBase\n  end\nend\n")
      expect(resolver.call('InhPending::LedgerClient', file_path: missing)).to be_nil

      framework = ledger("module InhPending\n  class LedgerClient < StandardError\n  end\nend\n")
      expect(resolver.call('InhPending::LedgerClient', file_path: framework)).to be_nil
    end

    it 'never reads a declaration from a file the autoload does not place the class in' do
      ledger("module InhPending\n  class LedgerClient < BaseClient\n  end\nend\n")
      stray = create_file('lib/vendored/ledger_client.rb',
                          "module InhPending\n  class LedgerClient < BaseClient\n  end\nend\n")

      expect(resolver.call('InhPending::LedgerClient', file_path: stray)).to be_nil
    end
  end

  # Ruby binds a relative parent in each enclosing scope's own constant
  # table first, innermost out, then in the innermost scope's ancestors,
  # then at the top level. A module the scope includes never outranks an
  # outer scope that defines the name itself (WDS-110). Every expectation
  # here is the superclass a separate Ruby process binds after loading the
  # same files, never a name read off the resolver.
  describe 'a pending library whose scope includes a module defining the parent name' do
    let(:child_path) { File.join(tmp_dir, 'lib/wds_outer/scope/child.rb') }
    let(:nested_child) { child_naming('WdsBase') }

    def child_naming(parent)
      "module WdsOuter\n  module Scope\n    class Child < #{parent}\n    end\n  end\nend\n"
    end

    after do
      %i[WdsOuter WdsAncestor WdsBase].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
      end
    end

    # Writes +files+ (relative path => source), loads every one but those in
    # +pending+ (relative path => [owner constant, name]), which are
    # registered as autoloads instead, and registers Child as a pending
    # autoload of WdsOuter::Scope.
    def scenario(files, child: nested_child, pending: {})
      paths = files.to_h { |relative, source| [relative, create_file(relative, source)] }
      paths.each { |relative, path| load path unless pending.key?(relative) }
      pending.each { |relative, (owner, name)| Object.const_get(owner).autoload(name, paths.fetch(relative)) }
      create_file('lib/wds_outer/scope/child.rb', child)
      WdsOuter::Scope.autoload(:Child, child_path)
      guard_const_missing
      paths.values
    end

    def guard_const_missing
      [WdsOuter, WdsOuter::Scope, WdsAncestor].each do |scope|
        scope.define_singleton_method(:const_missing) { |*| raise 'must not call const_missing' }
      end
    end

    # The parent Ruby itself binds: a fresh process requires the same files,
    # then Child's, and reads the superclass's constant name.
    def ruby_binding(paths)
      script = [*paths, child_path].map { |path| "require #{path.inspect}" }
      script << 'puts Module.instance_method(:name).bind_call(WdsOuter::Scope::Child.superclass)'
      output, status = Open3.capture2e(RbConfig.ruby, '--disable-gems', '-e', script.join("\n"))
      raise "ruby could not load the fixture: #{output}" unless status.success?

      output.strip
    end

    def pending_edge
      edge = resolver.call('WdsOuter::Scope::Child', file_path: child_path)
      expect(WdsOuter::Scope.autoload?(:Child)).to eq(child_path)
      edge
    end

    let(:ancestor) { ['lib/wds_ancestor.rb', "module WdsAncestor\n  class WdsBase\n  end\nend\n"] }
    let(:outer_base) { ['lib/wds_outer/wds_base.rb', "module WdsOuter\n  class WdsBase\n  end\nend\n"] }
    let(:scope) { ['lib/wds_outer/scope.rb', "module WdsOuter\n  module Scope\n    include WdsAncestor\n  end\nend\n"] }
    let(:top_base) { ['lib/wds_base.rb', "class WdsBase\nend\n"] }

    it 'binds the outer scope that defines the name, not the included module' do
      paths = scenario([ancestor, outer_base, scope])
      binding = ruby_binding(paths)

      expect(binding).to eq('WdsOuter::WdsBase')
      expect(pending_edge).to eq(type: :lib, target: binding, via: :inheritance)
    end

    it 'binds the outer scope when its parent is itself a pending autoload' do
      paths = scenario([ancestor, outer_base, scope], pending: { outer_base.first => %w[WdsOuter WdsBase] })
      binding = ruby_binding(paths)

      expect(binding).to eq('WdsOuter::WdsBase')
      expect(pending_edge).to eq(type: :lib, target: binding, via: :inheritance)
      expect(WdsOuter.autoload?(:WdsBase)).to eq(paths[1])
    end

    it 'binds the included module when no enclosing scope defines the name' do
      paths = scenario([ancestor, scope])
      binding = ruby_binding(paths)

      expect(binding).to eq('WdsAncestor::WdsBase')
      expect(pending_edge).to eq(type: :lib, target: binding, via: :inheritance)
    end

    it 'binds the included module ahead of a top-level class of the same name' do
      paths = scenario([top_base, ancestor, scope])
      binding = ruby_binding(paths)

      expect(binding).to eq('WdsAncestor::WdsBase')
      expect(pending_edge).to eq(type: :lib, target: binding, via: :inheritance)
    end

    it 'binds a qualified or rooted parent where it names, whatever the scope includes' do
      qualified = scenario([top_base, ancestor, outer_base, scope],
                           child: child_naming('WdsOuter::WdsBase'))
      expect(pending_edge).to eq(type: :lib, target: ruby_binding(qualified), via: :inheritance)

      rooted = scenario([top_base, ancestor, outer_base, scope],
                        child: child_naming('::WdsBase'))
      expect(ruby_binding(rooted)).to eq('WdsBase')
      expect(pending_edge).to eq(type: :lib, target: 'WdsBase', via: :inheritance)
    end

    it 'names the constant of an outer parent that overrides self.name' do
      named = ['lib/wds_outer/wds_base.rb',
               "module WdsOuter\n  class WdsBase\n    def self.name = 'Imposter'\n  end\nend\n"]
      paths = scenario([ancestor, named, scope])
      binding = ruby_binding(paths)

      expect(binding).to eq('WdsOuter::WdsBase')
      expect(pending_edge).to eq(type: :lib, target: binding, via: :inheritance)
    end
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
