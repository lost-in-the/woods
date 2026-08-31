# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'woods/dependency_graph'
require 'woods/flow_precomputer'

RSpec.describe Woods::FlowPrecomputer do
  let(:output_dir) { Dir.mktmpdir('flow_precomputer_test') }
  let(:graph) { Woods::DependencyGraph.new }

  after { FileUtils.remove_entry(output_dir) }

  # ── Helper ───────────────────────────────────────────────────────────

  def make_unit(type:, identifier:, file_path:, metadata: {}, source_code: '', dependencies: [])
    unit = Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: file_path)
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
      # Values are output_dir-relative (B-078 / #190) — resolve before stat.
      result.each_value do |path|
        expect(File.exist?(File.join(output_dir, path))).to eq(true)
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

    it 'raises when one action fails to assemble instead of publishing a partial index' do
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
      assembler_double = instance_double(Woods::FlowAssembler)
      allow(Woods::FlowAssembler).to receive(:new).and_return(assembler_double)

      ok_flow = Woods::FlowDocument.new(
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

      # A per-action skip would publish an index missing that entry while
      # the extraction continues — the full path is fail closed like the
      # incremental one, so the caller aborts before publishing.
      expect { precomputer.precompute }.to raise_error(Woods::ExtractionError, /parse error/)
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

      assembler_double = instance_double(Woods::FlowAssembler)
      allow(Woods::FlowAssembler).to receive(:new).and_return(assembler_double)

      flow = Woods::FlowDocument.new(
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

  # ── Relative paths + atomic writes (B-078 / #190) ──────────────────

  describe 'persisted path portability (B-078 / #190)' do
    def build_controller(identifier, actions)
      controller = make_unit(
        type: :controller,
        identifier: identifier,
        file_path: "app/controllers/#{identifier.downcase}.rb",
        metadata: { actions: actions },
        source_code: "class #{identifier} < ApplicationController\nend"
      )
      write_unit_json(controller)
      graph.register(controller)
      controller
    end

    it 'stores output_dir-relative paths in the map, flow_index.json, and metadata[:flow_paths]' do
      controller = build_controller('PortableController', %w[index])

      result = described_class.new(units: [controller], graph: graph, output_dir: output_dir).precompute

      expect(result['PortableController#index']).to eq('flows/PortableController_index.json')

      index = JSON.parse(File.read(File.join(output_dir, 'flows', 'flow_index.json')))
      expect(index['PortableController#index']).to eq('flows/PortableController_index.json')
      expect(index.values).to all(satisfy('be relative') { |v| !v.start_with?('/') })

      expect(controller.metadata[:flow_paths]['index']).to eq('flows/PortableController_index.json')
    end

    it 'remains resolvable when the index is served from a different mount point' do
      controller = build_controller('MountController', %w[show])

      flow = Woods::FlowDocument.new(entry_point: 'MountController#show', steps: [])
      assembler = instance_double(Woods::FlowAssembler)
      allow(assembler).to receive(:assemble).and_return(flow)
      allow(Woods::FlowAssembler).to receive(:new).and_return(assembler)

      original_root = Dir.mktmpdir('flow_mount_a')
      relocated_parent = Dir.mktmpdir('flow_mount_b')
      relocated_root = File.join(relocated_parent, 'woods')
      begin
        described_class.new(units: [controller], graph: graph, output_dir: original_root).precompute
        # Simulate extraction in a container (/app/...) read from a host
        # volume mount at a different prefix: move the whole output dir.
        FileUtils.mv(original_root, relocated_root)

        index = JSON.parse(File.read(File.join(relocated_root, 'flows', 'flow_index.json')))
        resolved = File.join(relocated_root, index.fetch('MountController#show'))
        expect(File.exist?(resolved)).to eq(true)
        expect(JSON.parse(File.read(resolved))['entry_point']).to eq('MountController#show')
      ensure
        FileUtils.rm_rf(original_root)
        FileUtils.rm_rf(relocated_parent)
      end
    end

    it 'writes flow documents and flow_index.json via AtomicFile' do
      controller = build_controller('AtomicController', %w[index])

      written = []
      allow(Woods::AtomicFile).to receive(:write).and_wrap_original do |original, path, content|
        written << path.to_s
        original.call(path, content)
      end

      described_class.new(units: [controller], graph: graph, output_dir: output_dir).precompute

      expect(written).to include(
        File.join(output_dir, 'flows', 'AtomicController_index.json'),
        File.join(output_dir, 'flows', 'flow_index.json')
      )
    end

    it 'round-trips non-ASCII flow content under the suite US-ASCII default external' do
      controller = build_controller('UnicodeController', %w[show])

      flow = Woods::FlowDocument.new(
        entry_point: 'UnicodeController#show',
        steps: [
          { unit: 'UnicodeController#show', type: 'controller',
            operations: [{ type: 'call', target: 'Svc', args_hint: 'label — em dash' }] }
        ]
      )
      assembler = instance_double(Woods::FlowAssembler)
      allow(assembler).to receive(:assemble).and_return(flow)
      allow(Woods::FlowAssembler).to receive(:new).and_return(assembler)

      described_class.new(units: [controller], graph: graph, output_dir: output_dir).precompute

      path = File.join(output_dir, 'flows', 'UnicodeController_show.json')
      parsed = JSON.parse(Woods::AtomicFile.read(path))
      hint = parsed['steps'].first['operations'].first['args_hint']
      expect(hint).to eq('label — em dash')
    end
  end

  # ── Collision-safe filenames (verified P1) ─────────────────────────
  #
  # FooController actions "bar.baz" and "bar_baz" both safe_segment to
  # "bar_baz" — the last writer used to win and flow_index.json pointed both
  # entries at one file.

  describe 'collision-safe flow filenames' do
    it 'keeps two actions that sanitize to the same segment separately addressable' do
      controller = make_unit(
        type: :controller,
        identifier: 'FooController',
        file_path: 'app/controllers/foo_controller.rb',
        metadata: { actions: ['bar.baz', 'bar_baz'] },
        source_code: "class FooController < ApplicationController\nend"
      )
      write_unit_json(controller)
      graph.register(controller)

      precomputer = described_class.new(units: [controller], graph: graph, output_dir: output_dir)
      result = precomputer.precompute

      expect(result.keys).to contain_exactly('FooController#bar.baz', 'FooController#bar_baz')
      expect(result.values.uniq.size).to eq(2)
      result.each_value { |path| expect(File.exist?(File.join(output_dir, path))).to eq(true) }

      index = JSON.parse(File.read(File.join(output_dir, 'flows', 'flow_index.json')))
      expect(index['FooController#bar.baz']).not_to eq(index['FooController#bar_baz'])
    end
  end

  # ── Deterministic output ───────────────────────────────────────────

  describe 'deterministic JSON output (J-1)' do
    it 'produces byte-identical JSON across runs with identical input' do
      controller = make_unit(
        type: :controller,
        identifier: 'StableController',
        file_path: 'app/controllers/stable_controller.rb',
        metadata: { actions: %w[index] },
        source_code: "class StableController < ApplicationController\n  def index; end\nend"
      )
      write_unit_json(controller)
      graph.register(controller)

      flow = Woods::FlowDocument.new(
        entry_point: 'StableController#index',
        route: { verb: 'GET', path: '/stable' },
        max_depth: 3,
        steps: [
          { unit: 'StableController', type: 'controller', operations: [] },
          { unit: 'StableService',    type: 'service',    operations: [] }
        ]
      )
      assembler = instance_double(Woods::FlowAssembler)
      allow(assembler).to receive(:assemble).and_return(flow)
      allow(Woods::FlowAssembler).to receive(:new).and_return(assembler)

      first_out = Dir.mktmpdir('flow_a')
      second_out = Dir.mktmpdir('flow_b')
      begin
        described_class.new(units: [controller], graph: graph, output_dir: first_out).precompute
        described_class.new(units: [controller], graph: graph, output_dir: second_out).precompute

        first_path = File.join(first_out, 'flows', 'StableController_index.json')
        second_path = File.join(second_out, 'flows', 'StableController_index.json')
        expect(File.read(first_path)).to eq(File.read(second_path))
      ensure
        FileUtils.rm_rf(first_out)
        FileUtils.rm_rf(second_out)
      end
    end
  end
end
