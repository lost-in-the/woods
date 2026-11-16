# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'

# A request flow follows the body Ruby dispatches for an action, which the
# controller extractor records in `action_sources`: a prepended override, a
# prepended override that calls `super`, the later of two local definitions,
# a local definition that wins over an included concern, and `super` from one
# prepended module into another or into a base controller. Each is checked
# against a real dispatch and the action's `UnboundMethod` owner, and the
# precomputed flow against the on-demand one. The flow follows one recorded
# `super` hop: past it (#index) it shows the call unresolved, never a guess.
# Of two definitions on one line in one owner, the later is read (#summary,
# #export); another owner's definition on that line is not (#preview).
# Every super call continues where Ruby makes it: twice (#twice), before a
# later statement on its line (#compact), and inside the branch or
# transaction that holds it (#gated, #locked), and as another call's
# receiver or argument (#handed).
RSpec.describe 'Request flow of the dispatched action body', :booted_app do
  actions = {
    'create' => { owner: 'ReplacedCreate', jobs: %w[ReplacedCreateJob] },
    'update' => { owner: 'SuperUpdate', jobs: %w[PrependedUpdateJob LocalUpdateJob] },
    'destroy' => { owner: 'ItemsController', jobs: %w[SecondDestroyJob] },
    'show' => { owner: 'ItemsController', jobs: %w[LocalShowJob] },
    'edit' => { owner: 'OuterEdit', jobs: %w[OuterEditJob InnerEditJob] },
    'archive' => { owner: 'PrependedArchive', jobs: %w[PrependedArchiveJob BaseArchiveJob] },
    'index' => { owner: 'OuterIndex', jobs: %w[OuterIndexJob InnerIndexJob LocalIndexJob],
                 flow_jobs: %w[OuterIndexJob InnerIndexJob], unfollowed_super: true },
    'summary' => { owner: 'ItemsController', jobs: %w[SecondSummaryJob] },
    'export' => { owner: 'ExportOverride', jobs: %w[SecondExportJob] },
    'preview' => { owner: 'ItemsController', jobs: %w[LocalPreviewJob] },
    'twice' => { owner: 'SuperCalls', jobs: %w[LocalTwiceJob BetweenJob LocalTwiceJob] },
    'compact' => { owner: 'SuperCalls', jobs: %w[LocalCompactJob AfterCompactJob] },
    'gated' => { owner: 'SuperCalls', jobs: %w[LocalGatedJob AfterGatedJob], held_by: 'conditional' },
    'locked' => { owner: 'SuperCalls', jobs: %w[LocalLockedJob AfterLockedJob], held_by: 'transaction' },
    'handed' => { owner: 'SuperCalls', jobs: %w[LocalHandedJob LocalHandedJob LocalHandedJob LocalHandedJob
                                                AfterHandedJob] }
  }

  before(:all) do
    @root = Dir.mktmpdir('woods-flow-action-owner')
    ENV['RAILS_ENV'] = 'test'
    require 'logger'
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'active_job/railtie'
    require 'woods'
    require 'woods/extractor'
    require 'woods/flow_assembler'
    write_application

    @app = Object.const_set(:WoodsFlowActionOwnerApplication, Class.new(Rails::Application))
    @app.config.root = @root
    @app.config.eager_load = false
    @app.config.secret_key_base = 'woods-flow-action-owner-fixture'
    @app.config.logger = Logger.new(File::NULL)
    @app.config.active_job.queue_adapter = :test
    @app.initialize!
    Rails.application.eager_load!

    @original_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.precompute_flows = true
    Woods.configuration.enable_snapshots = false
    @extractor = Woods::Extractor.new(output_dir: File.join(@root, 'index'))
    @results = @extractor.extract_all
    @extractor.raise_on_publication_failure!
  end

  after(:all) do
    Woods.configuration = @original_config if defined?(@original_config)
    FileUtils.remove_entry(@root) if @root
  end

  def write_application
    FileUtils.cp_r(File.join(File.expand_path('../fixtures/flow_action_owner', __dir__), '.'), @root)
    database = { 'test' => { 'adapter' => 'sqlite3', 'database' => ':memory:' } }
    File.write(File.join(@root, 'config', 'database.yml'), database.to_yaml)
  end

  def dispatched_jobs(action)
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ItemsController.new.public_send(action)
    ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:job].name }
  end

  def on_demand_flow(action)
    Woods::FlowAssembler.new(graph: @extractor.dependency_graph, extracted_dir: @extractor.payload_dir)
                        .assemble("ItemsController##{action}").to_h
  end

  def precomputed_flow(action)
    flows = File.join(@extractor.payload_dir.to_s, 'flows')
    index = JSON.parse(File.read(File.join(flows, 'flow_index.json')))
    JSON.parse(File.read(File.join(@extractor.payload_dir.to_s, index.fetch("ItemsController##{action}"))))
  end

  def entry_operations(flow)
    flow.fetch(flow.key?('steps') ? 'steps' : :steps).first.then { |step| step['operations'] || step[:operations] }
  end

  def unfollowed_super?(operations)
    operations.any? { |op| op[:type] == :dynamic_dispatch && op[:method] == 'super' }
  end

  # The jobs +operations+ enqueue, in order, nested operations included.
  def enqueued(operations)
    operations.flat_map do |op|
      op = op.transform_keys(&:to_s)
      next [op['target']] if op['type'].to_s == 'async'

      enqueued(%w[nested then_ops else_ops].flat_map { |key| op[key] || [] })
    end
  end

  # The type of the operation that holds every enqueued job, or nil when
  # they are not all held by one operation.
  def holder_type(operations)
    holders = operations.reject { |op| enqueued([op]).empty? }
    holders.one? ? holders.first.transform_keys(&:to_s)['type'].to_s : nil
  end

  actions.each do |action, expected|
    it "follows the body Ruby dispatches for ##{action}" do
      controller = @results.fetch(:controllers).find { |unit| unit.identifier == 'ItemsController' }

      expect(ItemsController.instance_method(action).owner.name).to eq(expected[:owner])
      expect(controller.metadata.dig(:action_sources, action, :owner)).to eq(expected[:owner])
      expect(dispatched_jobs(action)).to eq(expected[:jobs])

      operations = entry_operations(on_demand_flow(action))
      expect(enqueued(operations)).to eq(expected.fetch(:flow_jobs, expected[:jobs]))
      expect(unfollowed_super?(operations)).to eq(expected.fetch(:unfollowed_super, false))
      expect(operations.first[:method]).to eq('load_item')
      expect(enqueued(entry_operations(precomputed_flow(action)))).to eq(enqueued(operations))
      expect(holder_type(operations)).to eq(expected[:held_by]) if expected[:held_by]
    end
  end
end
