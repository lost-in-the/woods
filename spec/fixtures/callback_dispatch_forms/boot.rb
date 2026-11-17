# frozen_string_literal: true

# Boots a Rails app whose models define one callback method in several
# ways, saves a record of each, and prints, per model, what Ruby ran next to
# what model extraction published for it.

ENV['RAILS_ENV'] = 'test'

require 'rails'
require 'active_record/railtie'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'logger'
require 'woods'
require 'woods/extractor'

COLUMNS = %w[a b c d].freeze

def stamp(name, column, extra = '')
  "  def #{name}\n    self.#{column} = '#{column}'\n#{extra}  end\n"
end

# Two definitions of stamp on one line, in exclusive branches; +test+
# decides which one Ruby installs.
def branches(name, test)
  "class #{name} < ApplicationRecord\n  self.table_name = 'stamps'\n  before_save :stamp\n  " \
    "if 2.#{test} then def stamp; self.a = 'a'; end else def stamp; self.b = 'b'; end end\nend\n"
end

FILES = {
  'app/models/application_record.rb' => "class ApplicationRecord < ActiveRecord::Base\n  " \
                                        "self.abstract_class = true\nend\n",
  'app/models/redefined_record.rb' => "class RedefinedRecord < ApplicationRecord\n  self.table_name = 'stamps'\n  " \
                                      "before_save :stamp\n#{stamp('stamp', 'a')}#{stamp('stamp', 'b')}end\n",
  'app/models/concerns/stamp_override.rb' => "module StampOverride\n#{stamp('stamp', 'b')}end\n",
  'app/models/prepended_record.rb' => "class PrependedRecord < ApplicationRecord\n  self.table_name = 'stamps'\n  " \
                                      "prepend StampOverride\n  before_save :stamp\n#{stamp('stamp', 'a')}end\n",
  'app/models/concerns/stamp_chain.rb' => "module StampChain\n#{stamp('stamp', 'b', "    super\n")}end\n",
  'app/models/chained_record.rb' => "class ChainedRecord < ApplicationRecord\n  self.table_name = 'stamps'\n  " \
                                    "prepend StampChain\n  before_save :stamp\n#{stamp('stamp', 'a')}end\n",
  'app/models/sibling_record.rb' => "class StampHelper\n#{stamp('stamp', 'c')}end\n\n" \
                                    "class SiblingRecord < ApplicationRecord\n  self.table_name = 'stamps'\n  " \
                                    "before_save :stamp\n#{stamp('stamp', 'd')}end\n",
  'app/models/concerns/first_stamp.rb' => "module FirstStamp\n#{stamp('stamp', 'a')}end\n",
  'app/models/concerns/second_stamp.rb' => "module SecondStamp\n#{stamp('stamp', 'b')}end\n",
  'app/models/two_concern_record.rb' => "class TwoConcernRecord < ApplicationRecord\n  self.table_name = 'stamps'\n  " \
                                        "include FirstStamp\n  include SecondStamp\n  before_save :stamp\nend\n",
  'app/models/nested_record.rb' => "class NestedRecord < ApplicationRecord\n  self.table_name = 'stamps'\n  " \
                                   "before_save :stamp\n  class Helper\n    def stamp\n      self.c = 'c'\n    " \
                                   "end\n  end\n#{stamp('stamp', 'd')}end\n",
  'app/models/sti_stamp.rb' => "class StiStamp < ApplicationRecord\n  before_save :stamp\n#{stamp('stamp', 'a')}end\n",
  'app/models/sti_override_stamp.rb' => "class StiOverrideStamp < StiStamp\n#{stamp('stamp', 'b')}end\n",
  'app/models/sti_heir_stamp.rb' => "class StiHeirStamp < StiStamp\nend\n",
  'app/models/concerns/concern_stamped.rb' => "module ConcernStamped\n  extend ActiveSupport::Concern\n\n  " \
                                              "included do\n    before_save :concern_stamp\n  end\n\n" \
                                              "#{stamp('concern_stamp', 'c')}end\n",
  'app/models/included_record.rb' => "class IncludedRecord < ApplicationRecord\n  self.table_name = 'stamps'\n  " \
                                     "include ConcernStamped\n  before_save :stamp\n#{stamp('stamp', 'a')}end\n",
  'app/models/branch_then_record.rb' => branches('BranchThenRecord', 'even?'),
  'app/models/branch_else_record.rb' => branches('BranchElseRecord', 'odd?')
}.freeze

MODELS = %w[RedefinedRecord PrependedRecord ChainedRecord SiblingRecord TwoConcernRecord NestedRecord
            StiStamp StiOverrideStamp StiHeirStamp IncludedRecord BranchThenRecord BranchElseRecord].freeze

Dir.mktmpdir('woods_callback_dispatch_forms') do |root|
  FILES.each do |path, code|
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), code)
  end
  FileUtils.mkdir_p(File.join(root, 'config'))
  File.write(File.join(root, 'config/database.yml'),
             JSON.generate('test' => { adapter: 'sqlite3', database: ':memory:' }))

  app = Class.new(Rails::Application)
  Object.const_set(:CallbackDispatchFormsApplication, app)
  app.config.root = root
  app.config.eager_load = false
  app.config.secret_key_base = 'callback-dispatch-forms-fixture'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  ActiveRecord::Schema.verbose = false
  ActiveRecord::Schema.define do
    create_table(:stamps) { |t| COLUMNS.each { |column| t.string column } }
    create_table(:sti_stamps) do |t|
      COLUMNS.each { |column| t.string column }
      t.string :type
    end
  end
  Rails.application.eager_load!
  Woods.configure { |config| config.include_framework_sources = false }

  extractor = Woods::Extractors::ModelExtractor.new
  units = extractor.extract_all.to_h { |unit| [unit.identifier, unit] }
  raise extractor.warnings.join("\n") unless (MODELS - units.keys).empty?

  site = ->(location) { location && [location.first.delete_prefix("#{Rails.root}/"), location.last] }
  report = MODELS.to_h do |name|
    model = name.constantize
    saved = model.create!.attributes.slice(*COLUMNS).compact.keys.sort
    callbacks = units.fetch(name).metadata[:callbacks].select { |cb| %w[stamp concern_stamp].include?(cb[:filter]) }
    [name, {
      saved: saved,
      dispatched: callbacks.to_h { |cb| [cb[:filter], site.call(model.instance_method(cb[:filter]).source_location)] },
      published: callbacks.to_h do |cb|
        [cb[:filter], { status: cb[:analysis_status], columns: cb[:side_effects][:columns_written],
                        sites: cb[:side_effects][:operations].map { |op| [op[:file], op[:line]] } }]
      end
    }]
  end
  puts JSON.generate(rails: Rails.version, models: report)
end
