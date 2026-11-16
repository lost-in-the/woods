# frozen_string_literal: true

# Boots a Rails app whose state machines name one transition callback method
# defined in several ways, fires each machine's event, and prints the jobs
# the callbacks Ruby ran enqueued next to what extraction published.

ENV['RAILS_ENV'] = 'test'

require 'rails'
require 'active_record/railtie'
require 'state_machines'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'logger'
require 'woods'
require 'woods/extractor'

RUNS = [] # rubocop:disable Style/MutableConstant -- the jobs the callbacks enqueue, in order

%w[FirstStampJob SecondStampJob LocalStampJob OverrideStampJob ChainStampJob HelperStampJob SiblingStampJob
   PlainStampJob ConcernStampJob BlockStampJob].each do |job|
  Object.const_set(job, Class.new { define_singleton_method(:perform_later) { |*| RUNS << job } })
end

def machine(name, body, callback: 'after_transition on: :go, do: :stamp', head: '')
  "class #{name}\n#{head}  state_machine initial: :idle do\n    event(:go) { transition idle: :busy }\n    " \
    "#{callback}\n  end\n#{body}end\n"
end

def stamp(job, extra = '')
  "  def stamp\n    #{job}.perform_later\n#{extra}  end\n"
end

FILES = {
  'app/models/redefined_machine.rb' => machine('RedefinedMachine', stamp('FirstStampJob') + stamp('SecondStampJob')),
  'app/models/concerns/stamp_override.rb' => "module StampOverride\n#{stamp('OverrideStampJob')}end\n",
  'app/models/prepended_machine.rb' => machine('PrependedMachine', stamp('LocalStampJob'),
                                               head: "  prepend StampOverride\n"),
  'app/models/concerns/stamp_chain.rb' => "module StampChain\n#{stamp('ChainStampJob', "    super\n")}end\n",
  'app/models/chained_machine.rb' => machine('ChainedMachine', stamp('LocalStampJob'), head: "  prepend StampChain\n"),
  'app/models/sibling_machine.rb' => "class StampHelper\n#{stamp('HelperStampJob')}end\n\n" +
                                     machine('SiblingMachine', stamp('SiblingStampJob')),
  'app/models/plain_machine.rb' => machine('PlainMachine', stamp('PlainStampJob')),
  'app/models/concerns/concern_stamp.rb' => "module ConcernStamp\n#{stamp('ConcernStampJob')}end\n",
  'app/models/concern_machine.rb' => machine('ConcernMachine', '', head: "  include ConcernStamp\n"),
  'app/models/block_machine.rb' => machine('BlockMachine', '',
                                           callback: 'after_transition(on: :go) { BlockStampJob.perform_later }')
}.freeze

MACHINES = %w[RedefinedMachine PrependedMachine ChainedMachine SiblingMachine PlainMachine ConcernMachine
              BlockMachine].freeze

Dir.mktmpdir('woods_transition_callback_forms') do |root|
  FILES.each do |path, code|
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), code)
  end
  FileUtils.mkdir_p(File.join(root, 'config'))
  File.write(File.join(root, 'config/database.yml'),
             JSON.generate('test' => { adapter: 'sqlite3', database: ':memory:' }))

  app = Class.new(Rails::Application)
  Object.const_set(:TransitionCallbackFormsApplication, app)
  app.config.root = root
  app.config.eager_load = false
  app.config.secret_key_base = 'transition-callback-forms-fixture'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  Rails.application.eager_load!
  Woods.configure do |config|
    config.concurrent_extraction = false
    config.enable_snapshots = false
    config.include_framework_sources = false
  end

  units = Woods::Extractors::StateMachineExtractor.new.extract_all.to_h { |unit| [unit.metadata[:model_name], unit] }
  raise "missing machines: #{units.keys.inspect}" unless (MACHINES - units.keys).empty?

  report = MACHINES.to_h do |name|
    RUNS.clear
    name.constantize.new.go
    entry = units.fetch(name).metadata[:transition_callbacks].first
    [name, { ran: RUNS.dup, method: entry[:method], block: entry[:block], unanalysed: entry[:unanalysed],
             published: entry[:side_effects] && entry[:side_effects][:jobs_enqueued],
             sites: entry[:side_effects] && entry[:side_effects][:operations].map { |op| op[:file] }.uniq }]
  end
  puts JSON.generate(rails: Rails.version, machines: report)
end
