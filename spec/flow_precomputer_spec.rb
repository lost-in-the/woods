# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'codebase_index/dependency_graph'
require 'codebase_index/flow_precomputer'

RSpec.describe CodebaseIndex::FlowPrecomputer do
  let(:output_dir) { Dir.mktmpdir('flow_precomputer_test') }
  let(:graph) { CodebaseIndex::DependencyGraph.new }

  after { FileUtils.remove_entry(output_dir) }

  # ── Helper ───────────────────────────────────────────────────────────

  def make_unit(type:, identifier:, file_path:, metadata: {}, source_code: '', dependencies: [])
    unit = CodebaseIndex::ExtractedUnit.new(type: type, identifier: identifier, file_path: file_path)
    unit.metadata = metadata
    unit.source_code = source_code
    unit.dependencies = dependencies
    unit
  end

  def write_unit_json(unit)
    type_dir = File.join(output_dir, "#{unit.type}s")
    FileUtils.mkdir_p(type_dir)
    filename = "#{unit.identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')}.json"
    File.write(File.join(type_dir, filename), JSON.generate(unit.to_h))
  end

  # ── Basic behavior ──────────────────────────────────────────────────

  describe '#precompute' do
    it 'returns a hash mapping entry points to flow file paths' do
      controller = make_unit(
        type: :controller,
        identifier: 'PostsController',
        file_path: 'app/controllers/posts_controller.rb',
        metadata: {
          actions: %w[index create],
          filters: [
            { kind: :before, filter: :authenticate_user! }
          ]
        },
        source_code: <<~RUBY
          class PostsController < ApplicationController
            def index
              @posts = Post.all
            end

            def create
              Post.create!(params)
            end
          end
        RUBY
      )
      write_unit_json(controller)
      graph.register(controller)

      precomputer = described_class.new(units: [controller], graph: graph, output_dir: output_dir)
      result = precomputer.precompute

      expect(result).to be_a(Hash)
      expect(result.keys).to contain_exactly('PostsController#index', 'PostsController#create')
      result.each_value do |path|
        expect(File.exist?(path)).to eq(true)
      end
    end

    it 'writes flow documents as JSON files' do
      controller = make_unit(
        type: :controller,
        identifier: 'OrdersController',
        file_path: 'app/controllers/orders_controller.rb',
        metadata: { actions: %w[create] },
        source_code: <<~RUBY
          class OrdersController < ApplicationController
            def create
              Order.create!(params)
            end
          end
        RUBY
      )
      write_unit_json(controller)
      graph.register(controller)

      precomputer = described_class.new(units: [controller], graph: graph, output_dir: output_dir)
      precomputer.precompute

      flow_path = File.join(output_dir, 'flows', 'OrdersController_create.json')
      expect(File.exist?(flow_path)).to eq(true)

      flow_data = JSON.parse(File.read(flow_path), symbolize_names: true)
      expect(flow_data[:entry_point]).to eq('OrdersController#create')
      expect(flow_data[:steps]).to be_an(Array)
    end

    it 'writes flow_index.json' do
      controller = make_unit(
        type: :controller,
        identifier: 'UsersController',
        file_path: 'app/controllers/users_controller.rb',
        metadata: { actions: %w[show] },
        source_code: <<~RUBY
          class UsersController < ApplicationController
            def show
              @user = User.find(params[:id])
            end
          end
        RUBY
      )
      write_unit_json(controller)
      graph.register(controller)

      precomputer = described_class.new(units: [controller], graph: graph, output_dir: output_dir)
      precomputer.precompute

      index_path = File.join(output_dir, 'flows', 'flow_index.json')
      expect(File.exist?(index_path)).to eq(true)

      index = JSON.parse(File.read(index_path))
      expect(index).to have_key('UsersController#show')
    end

    it 'adds flow references to controller unit metadata' do
      controller = make_unit(
        type: :controller,
        identifier: 'ItemsController',
        file_path: 'app/controllers/items_controller.rb',
        metadata: { actions: %w[index] },
        source_code: <<~RUBY
          class ItemsController < ApplicationController
            def index
              @items = Item.all
            end
          end
        RUBY
      )
      write_unit_json(controller)
      graph.register(controller)

      precomputer = described_class.new(units: [controller], graph: graph, output_dir: output_dir)
      precomputer.precompute

      expect(controller.metadata[:flow_paths]).to be_a(Hash)
      expect(controller.metadata[:flow_paths]).to have_key('index')
    end
  end

  # ── Controller with filters ────────────────────────────────────────

  describe 'controller with filters' do
    it 'includes before_action filters in flow steps' do
      controller = make_unit(
        type: :controller,
        identifier: 'AdminController',
        file_path: 'app/controllers/admin_controller.rb',
        metadata: {
          actions: %w[dashboard],
          filters: [
            { kind: :before, filter: :require_admin }
          ]
        },
        source_code: <<~RUBY
          class AdminController < ApplicationController
            def dashboard
              @stats = Stats.compute
            end
          end
        RUBY
      )
      write_unit_json(controller)
      graph.register(controller)

      precomputer = described_class.new(units: [controller], graph: graph, output_dir: output_dir)
      precomputer.precompute

      flow_path = File.join(output_dir, 'flows', 'AdminController_dashboard.json')
      flow_data = JSON.parse(File.read(flow_path), symbolize_names: true)

      ops = flow_data[:steps].first[:operations]
      callback_op = ops.find { |o| o[:method] == 'require_admin' }
      expect(callback_op).not_to be_nil
    end
  end

  # ── Multiple controllers ────────────────────────────────────────────

  describe 'multiple controllers' do
    it 'processes all controller units' do
      ctrl_a = make_unit(
        type: :controller,
        identifier: 'AController',
        file_path: 'app/controllers/a_controller.rb',
        metadata: { actions: %w[index] },
        source_code: "class AController < ApplicationController\n  def index; end\nend"
      )
      ctrl_b = make_unit(
        type: :controller,
        identifier: 'BController',
        file_path: 'app/controllers/b_controller.rb',
        metadata: { actions: %w[show] },
        source_code: "class BController < ApplicationController\n  def show; end\nend"
      )
      [ctrl_a, ctrl_b].each do |u|
        write_unit_json(u)
        graph.register(u)
      end

      precomputer = described_class.new(units: [ctrl_a, ctrl_b], graph: graph, output_dir: output_dir)
      result = precomputer.precompute

      expect(result.keys).to contain_exactly('AController#index', 'BController#show')
    end
  end

  # ── Edge cases ─────────────────────────────────────────────────────

  describe 'edge cases' do
    it 'handles controller with no actions gracefully' do
      controller = make_unit(
        type: :controller,
        identifier: 'EmptyController',
        file_path: 'app/controllers/empty_controller.rb',
        metadata: { actions: [] },
        source_code: "class EmptyController < ApplicationController\nend"
      )
      write_unit_json(controller)
      graph.register(controller)

      precomputer = described_class.new(units: [controller], graph: graph, output_dir: output_dir)
      result = precomputer.precompute

      expect(result).to eq({})
    end

    it 'handles controller with nil actions gracefully' do
      controller = make_unit(
        type: :controller,
        identifier: 'NoActionsController',
        file_path: 'app/controllers/no_actions_controller.rb',
        metadata: {},
        source_code: "class NoActionsController < ApplicationController\nend"
      )
      write_unit_json(controller)
      graph.register(controller)

      precomputer = described_class.new(units: [controller], graph: graph, output_dir: output_dir)
      result = precomputer.precompute

      expect(result).to eq({})
    end

    it 'skips non-controller units' do
      service = make_unit(
        type: :service,
        identifier: 'PostService',
        file_path: 'app/services/post_service.rb',
        metadata: {},
        source_code: "class PostService\n  def call; end\nend"
      )
      write_unit_json(service)
      graph.register(service)

      precomputer = described_class.new(units: [service], graph: graph, output_dir: output_dir)
      result = precomputer.precompute

      expect(result).to eq({})
    end

    it 'handles FlowAssembler errors gracefully per action' do
      controller = make_unit(
        type: :controller,
        identifier: 'BadController',
        file_path: 'app/controllers/bad_controller.rb',
        metadata: { actions: %w[ok broken] },
        source_code: <<~RUBY
          class BadController < ApplicationController
            def ok
              render plain: 'ok'
            end

            def broken
              do_something
            end
          end
        RUBY
      )
      write_unit_json(controller)
      graph.register(controller)

      # Stub FlowAssembler to raise only for the broken action
      assembler_double = instance_double(CodebaseIndex::FlowAssembler)
      allow(CodebaseIndex::FlowAssembler).to receive(:new).and_return(assembler_double)

      ok_flow = CodebaseIndex::FlowDocument.new(
        entry_point: 'BadController#ok',
        steps: [{ unit: 'BadController#ok', type: 'controller', operations: [] }]
      )
      allow(assembler_double).to receive(:assemble)
        .with('BadController#ok', max_depth: 3)
        .and_return(ok_flow)
      allow(assembler_double).to receive(:assemble)
        .with('BadController#broken', max_depth: 3)
        .and_raise(StandardError, 'parse error')

      logger = double('Logger', error: nil, warn: nil, info: nil, debug: nil)
      stub_const('Rails', double('Rails', logger: logger))

      precomputer = described_class.new(units: [controller], graph: graph, output_dir: output_dir)
      result = precomputer.precompute

      # Should still have the ok action
      expect(result).to have_key('BadController#ok')
      expect(result).not_to have_key('BadController#broken')
    end
  end

  # ── Depth limiting ─────────────────────────────────────────────────

  describe 'depth limiting' do
    it 'passes max_depth to FlowAssembler' do
      controller = make_unit(
        type: :controller,
        identifier: 'DeepController',
        file_path: 'app/controllers/deep_controller.rb',
        metadata: { actions: %w[go] },
        source_code: "class DeepController < ApplicationController\n  def go; end\nend"
      )
      write_unit_json(controller)
      graph.register(controller)

      assembler_double = instance_double(CodebaseIndex::FlowAssembler)
      allow(CodebaseIndex::FlowAssembler).to receive(:new).and_return(assembler_double)

      flow = CodebaseIndex::FlowDocument.new(
        entry_point: 'DeepController#go',
        steps: []
      )
      expect(assembler_double).to receive(:assemble)
        .with('DeepController#go', max_depth: 3)
        .and_return(flow)

      precomputer = described_class.new(units: [controller], graph: graph, output_dir: output_dir)
      precomputer.precompute
    end
  end
end
