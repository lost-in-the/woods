# frozen_string_literal: true

# Boots a Rails app whose model file declares scopes in several ways, runs a
# full extraction, and prints what the live classes answer next to the
# scopes and scope spans each model unit publishes. No scope is called.

ENV['RAILS_ENV'] = 'test'

require 'rails'
require 'active_record/railtie'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'logger'
require 'woods'
require 'woods/extractor'

ENUM = if ActiveRecord::VERSION::MAJOR >= 7
         'enum :status, { active: 0, archived: 1 }'
       else
         'enum status: { active: 0, archived: 1 }'
       end
# An enum that declines its scopes beside an explicit scope named for a value.
# Rails 7.0 added the positional form; 8.0 removed the `_scopes:` keyword one.
SCOPELESS_ENUM = if ActiveRecord::VERSION::MAJOR >= 7
                   'enum :plan, { basic: 0, premium: 1 }, scopes: false'
                 else
                   'enum plan: { basic: 0, premium: 1 }, _scopes: false'
                 end
PREFIXED_ENUM = if ActiveRecord::VERSION::MAJOR >= 7
                  'enum :tone, { warm: 0, cool: 1 }, prefix: true'
                else
                  'enum tone: { warm: 0, cool: 1 }, _prefix: true'
                end
# Rails 7.1 added `instance_methods: false`: the value scopes without the predicates.
BARE_ENUM = if ActiveRecord.version >= Gem::Version.new('7.1')
              "enum :tier, { gold: 0 }, instance_methods: false\n  if false\n    scope :gold, -> { none }\n  end"
            else
              ''
            end

FILES = {
  'app/models/application_record.rb' => "class ApplicationRecord < ActiveRecord::Base\n  " \
                                        "self.abstract_class = true\nend\n",
  'app/models/scope_owner.rb' => <<~RUBY
    class ScopeOwner < ApplicationRecord
      scope :own_scope, -> { where(label: 'own') }

      class NestedScoped < ApplicationRecord
        self.table_name = 'scope_owners'
        scope :nested_scope, -> { where(label: 'nested') }
      end

      if false
        scope :dead_scope, -> { where(label: 'dead') }
        scope :dead_twin, -> { where(label: 'twin') }
        scope :active, -> { where(label: 'enum twin') }
      end

      def self.dead_twin
        where(label: 'class method')
      end

      def install_later
        self.class.scope(:deferred_scope, -> { where(label: 'later') })
      end

      def install_bare
        scope :bare_scope, -> { where(label: 'bare') }
      end

      #{ENUM}
      #{BARE_ENUM}
      #{SCOPELESS_ENUM}
      #{PREFIXED_ENUM}
      if false
        scope :tone_warm, -> { none }
      end
      scope :basic, -> { where(label: 'explicit') }
    end
  RUBY
}.freeze

NAMES = %w[own_scope nested_scope dead_scope dead_twin active gold basic not_basic tone_warm deferred_scope
           bare_scope].freeze
MODELS = %w[ScopeOwner ScopeOwner::NestedScoped].freeze

Dir.mktmpdir('woods_scope_owner_forms') do |root|
  FILES.each do |path, code|
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), code)
  end
  FileUtils.mkdir_p(File.join(root, 'config'))
  File.write(File.join(root, 'config/database.yml'),
             JSON.generate('test' => { adapter: 'sqlite3', database: ':memory:' }))

  app = Class.new(Rails::Application)
  Object.const_set(:ScopeOwnerFormsApplication, app)
  app.config.root = root
  app.config.eager_load = false
  app.config.secret_key_base = 'scope-owner-forms-fixture'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  ActiveRecord::Schema.verbose = false
  ActiveRecord::Schema.define do
    create_table(:scope_owners) do |t|
      t.string :label
      t.integer :status
      t.integer :tier
      t.integer :plan
      t.integer :tone
    end
  end
  Rails.application.eager_load!
  Woods.configure do |config|
    config.concurrent_extraction = false
    config.enable_snapshots = false
    config.include_framework_sources = false
  end

  extractor = Woods::Extractor.new(output_dir: File.join(root, 'tmp/index'))
  units = extractor.extract_all.fetch(:models).to_h { |unit| [unit.identifier, unit] }
  extractor.raise_on_publication_failure!
  raise "missing model units: #{units.keys.inspect}" unless (MODELS - units.keys).empty?

  report = MODELS.to_h do |name|
    model = name.constantize
    unit = units.fetch(name)
    spans = Array(unit.metadata[:references]).select { |ref| (ref['kind'] || ref[:kind]).to_s == 'scope' }
    [name, {
      answers: NAMES.select { |scope| model.respond_to?(scope) }.to_h do |scope|
        method = model.method(scope)
        [scope, { 'site' => File.basename(method.source_location.first),
                  'own' => method.owner == model.singleton_class }]
      end,
      scopes: unit.metadata[:scopes].to_h { |entry| [entry[:name], entry[:confidence]] },
      spans: spans.to_h { |ref| [ref['method'] || ref[:method], ref['confidence'] || ref[:confidence]] }
    }]
  end
  puts JSON.generate(rails: Rails.version, models: report)
end
