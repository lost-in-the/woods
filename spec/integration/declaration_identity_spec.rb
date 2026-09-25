# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'woods/generation'
require_relative '../support/source_input_app'

RSpec.describe 'Booted declaration identity contracts', :booted_app do
  include SourceInputApp

  let(:root) { File.expand_path('../..', __dir__) }

  def write(app, path, source)
    target = File.join(app, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, source)
  end

  def command(app)
    [RbConfig.ruby, '-I', File.join(root, 'lib'), File.join(root, 'exe/woods-extract'), '--root', app, 'full']
  end

  def units(app, type)
    payload = Woods::Generation.new(output_dir: File.join(app, 'tmp/woods')).payload_dir
    Dir[File.join(payload, type, '*.json')].filter_map do |path|
      JSON.parse(File.read(path, encoding: 'UTF-8')) unless File.basename(path) == '_index.json'
    end
  end

  def migration_source(name, table)
    <<~RUBY
      raise 'historical migration evaluated by extraction'
      class MigrationHelper < ActiveRecord::Base; end
      class #{name} < ::ActiveRecord::Migration[6.0]
        def change
          create_table :#{table} do |t|
            t.string :label
          end
        end
      end
    RUBY
  end

  it 'reflects custom manager and policy bases and publishes distinct historical migrations without executing them' do
    Dir.mktmpdir('woods-declaration-rails') do |app|
      make_source_app(app)
      write(app, 'config/initializers/delegation.rb', "require 'delegate'\n")
      write(app, 'config/initializers/declaration_namespaces.rb',
            "module DeclarationOuter; end\nmodule DeclarationRoot; end\n")
      write(app, 'app/managers/base_manager.rb', "class BaseManager < ::SimpleDelegator; end\n")
      write(app, 'app/managers/order_manager.rb', "class OrderManager < BaseManager; end\n")
      write(app, 'app/managers/unrelated_manager.rb', "class UnrelatedManager; end\n")
      write(app, 'app/policies/application_policy.rb', <<~RUBY)
        class ApplicationPolicy
          attr_reader :user, :record
          def initialize(user, record)
            @user, @record = user, record
          end
        end
      RUBY
      write(app, 'app/policies/base_policy.rb', "class BasePolicy < ApplicationPolicy; end\n")
      write(app, 'app/policies/order_policy.rb', "class OrderPolicy < BasePolicy; end\n")
      write(app, 'app/policies/admin/application_policy.rb',
            "class Admin::ApplicationPolicy < ::ApplicationPolicy; end\n")
      write(app, 'app/policies/admin/order_policy.rb', "class Admin::OrderPolicy < Admin::ApplicationPolicy; end\n")
      write(app, 'app/policies/refund_policy.rb', "class RefundPolicy; end\n")
      write(app, 'db/migrate/20260101000000_create_accounts.rb', migration_source('CreateAccounts', 'accounts'))
      write(app, 'db/migrate/20260102000000_create_entries.rb', migration_source('CreateEntries', 'entries'))
      write(app, 'db/migrate/20260102500000_create_audits.rb', <<~RUBY)
        raise 'historical migration evaluated by extraction'
        module DeclarationOuter
          class DeclarationRoot::CreateAudits < ActiveRecord::Migration[6.0]
            def change
              create_table :audits
            end
          end
        end
      RUBY

      out, err, result = Open3.capture3(*command(app))
      expect(result).to be_success, "#{out}\n#{err}"
      managers = units(app, 'managers')
      expect(managers).to include(include('identifier' => 'OrderManager',
                                          'metadata' => include('delegation_type' => 'simple_delegator')))
      expect(managers.map { |unit| unit['identifier'] }).not_to include('UnrelatedManager')
      pundit = units(app, 'pundit_policies')
      %w[OrderPolicy Admin::OrderPolicy].each do |name|
        expect(pundit).to include(include('identifier' => name,
                                          'metadata' => include('inherits_application_policy' => true)))
      end
      expect(pundit.map { |unit| unit['identifier'] }).not_to include('RefundPolicy')
      policies = units(app, 'policies')
      expect(policies).to include(include('identifier' => 'OrderPolicy', 'metadata' => include('is_pundit' => true)))
      migrations = units(app, 'migrations')
      expect(migrations.map do |unit|
        unit['identifier']
      end).to contain_exactly('CreateAccounts', 'CreateEntries', 'DeclarationRoot::CreateAudits')
      expect(migrations.map do |unit|
        unit.dig('metadata', 'tables_affected')
      end).to contain_exactly(['accounts'], ['entries'], ['audits'])

      pointer = File.binread(File.join(app, 'tmp/woods/generation.json'))
      write(app, 'db/migrate/20260103000000_duplicate_accounts.rb', migration_source('CreateAccounts', 'accounts'))
      _out, err, collision = Open3.capture3(*command(app))
      expect(collision).not_to be_success
      expect(err).to include('CreateAccounts')
      expect(File.binread(File.join(app, 'tmp/woods/generation.json'))).to eq(pointer)
    end
  end
end
