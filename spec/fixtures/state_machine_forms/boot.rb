# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'

require 'rails'
require 'active_record/railtie'
require 'state_machines'
require 'aasm'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extractor'
require_relative '../../support/index_comparison'

def verify(message)
  raise message unless yield
end

def event_facts(event)
  transitions = event.branches.flat_map do |branch|
    branch.state_requirements.flat_map do |requirement|
      requirement[:from].values.product(requirement[:to].values).map do |from, to|
        { from: from.to_s, to: to.to_s, guard: nil }
      end
    end
  end
  { name: event.name.to_s, transitions: transitions }
end

def machine_facts(machine)
  events = machine.events.map { |event| event_facts(event) }
  { states: machine.states.map { |state| state.name.to_s },
    initial_state: machine.states.find(&:initial?)&.name&.to_s,
    events: events, transitions: events.flat_map { |event| event[:transitions] } }
end

Dir.mktmpdir('woods_state_machine_forms') do |root|
  FileUtils.mkdir_p(File.join(root, 'app/models'))
  FileUtils.mkdir_p(File.join(root, 'config'))
  File.write(File.join(root, 'config/database.yml'),
             JSON.generate('test' => { adapter: 'sqlite3', database: ':memory:' }))
  source = File.join(root, 'app/models/form_machines.rb')
  File.write(source, <<~RUBY)
    class FormMachines
      def self.new(*)
        raise 'extractor must not construct model instances'
      end

      state_machine initial: :pending do
        state :pending
        state :active
        before_transition do
          raise 'default machine callback executed'
        end
        event :activate do
          transition pending: :active
        end
      end

      state_machine(
        :payment_status,
        initial: :unpaid
      ) do
        state :unpaid
        state :paid
        after_transition do
          raise 'payment callback executed'
        end
        event :pay do
          transition unpaid: :paid
        end
      end

      state_machine :delivery_status, initial: :waiting do
        state :waiting
        state :delivered
        event :deliver do
          transition waiting: :delivered
        end
      end
    end
  RUBY
  File.write(File.join(root, 'app/models/aasm_control.rb'), <<~RUBY)
    class AasmControl
      include AASM
      aasm do
        state :pending, initial: true
        state :active
        event :activate do
          transitions from: :pending, to: :active
        end
      end
    end
  RUBY

  app = Class.new(Rails::Application)
  Object.const_set(:StateMachineFormsApplication, app)
  app.config.root = root
  app.config.eager_load = false
  app.config.cache_classes = false
  app.config.secret_key_base = 'state-machine-forms-fixture'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  Rails.application.eager_load!
  Woods.configure do |config|
    config.concurrent_extraction = false
    config.enable_snapshots = false
    config.include_framework_sources = false
  end

  verify_registry = lambda do
    units = Woods::Extractors::StateMachineExtractor.new.extract_all
    machines = units.select { |unit| unit.metadata[:gem_detected] == 'state_machines' }
    verify('default and named machines have distinct stable identifiers') do
      machines.map(&:identifier) == %w[FormMachines::state_machine_state
                                       FormMachines::state_machine_payment_status
                                       FormMachines::state_machine_delivery_status]
    end
    FormMachines.state_machines.each do |name, machine|
      unit = machines.find { |candidate| candidate.identifier == "FormMachines::state_machine_#{name}" }
      facts = machine_facts(machine)
      verify("extracted facts agree with runtime #{name}") { unit.metadata.slice(*facts.keys) == facts }
    end
    aasm = units.find { |unit| unit.identifier == 'AasmControl::aasm' }
    verify('AASM extraction is unchanged') do
      aasm.metadata[:states] == AasmControl.aasm.states.map { |state| state.name.to_s } &&
        aasm.metadata[:events].map { |event| event[:name] } == AasmControl.aasm.events.map { |event| event.name.to_s }
    end
  end
  verify_registry.call

  output = File.join(root, 'tmp/index')
  runner = Woods::Extractor.new(output_dir: output)
  runner.extract_all
  runner.raise_on_publication_failure!
  File.write(source, File.read(source).gsub(':active', ':completed'))
  Rails.application.reloader.reload!
  runner.extract_changed([source])
  runner.raise_on_publication_failure!
  verify_registry.call
  compare = lambda do
    Dir.mktmpdir('woods_state_machine_oracle') do |oracle|
      fresh = Woods::Extractor.new(output_dir: oracle)
      fresh.extract_all
      fresh.raise_on_publication_failure!
      differences = IndexComparison.differences(output, oracle)
      raise "state-machine equivalence: #{differences.inspect}" unless differences.empty?
    end
  end
  compare.call
  runner.refresh(:state_machines)
  runner.raise_on_publication_failure!
  compare.call
  puts JSON.generate('checks' => ['default and named machines', 'runtime registry facts', 'AASM control',
                                  'full/incremental/refresh equivalence', 'no callback execution'])
end
