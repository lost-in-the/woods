# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'codebase_index/dependency_graph'
require 'codebase_index/flow_assembler'
require 'codebase_index/flow_document'

RSpec.describe CodebaseIndex::FlowAssembler do
  let(:graph) { instance_double(CodebaseIndex::DependencyGraph) }
  let(:extracted_dir) { Dir.mktmpdir('flow_assembler_test') }

  after { FileUtils.remove_entry(extracted_dir) }

  def write_unit(identifier, source_code:, type: 'controller', metadata: {}, dependencies: [])
    data = {
      'type' => type,
      'identifier' => identifier,
      'file_path' => "app/#{type}s/#{identifier.downcase}.rb",
      'source_code' => source_code,
      'metadata' => metadata,
      'dependencies' => dependencies
    }
    # Mirror the extractor's output layout: <type>s/<collision_safe_filename>.json
    type_dir = File.join(extracted_dir, "#{type}s")
    FileUtils.mkdir_p(type_dir)
    base = identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
    digest = Digest::SHA256.hexdigest(identifier)[0, 8]
    filename = "#{base}_#{digest}.json"
    File.write(File.join(type_dir, filename), JSON.generate(data))
  end

  # Shared helpers to stub graph methods with safe defaults.
  # Tests that need specific behavior override these stubs individually.
  def stub_graph_defaults
    allow(graph).to receive(:node_exists?).and_return(false)
    allow(graph).to receive(:find_node_by_suffix).and_return(nil)
  end

  describe '#assemble' do
    it 'produces a FlowDocument' do
      write_unit('PostsController', source_code: <<~RUBY)
        class PostsController < ApplicationController
          def create
            PostService.call(params)
            render_created(result)
          end
        end
      RUBY

      stub_graph_defaults

      assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
      flow = assembler.assemble('PostsController#create')

      expect(flow).to be_a(CodebaseIndex::FlowDocument)
      expect(flow.entry_point).to eq('PostsController#create')
      expect(flow.steps.size).to eq(1)
      expect(flow.steps[0][:unit]).to eq('PostsController#create')
    end

    it 'extracts operations from the specified method' do
      write_unit('PostsController', source_code: <<~RUBY)
        class PostsController < ApplicationController
          def create
            PostService.call(params)
            render_created(result)
          end
        end
      RUBY

      stub_graph_defaults

      assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
      flow = assembler.assemble('PostsController#create')

      ops = flow.steps[0][:operations]
      expect(ops.any? { |o| o[:type] == :call && o[:method] == 'call' }).to be true
      expect(ops.any? { |o| o[:type] == :response }).to be true
    end

    it 'recursively expands targets that resolve to known units' do
      write_unit('PostsController', source_code: <<~RUBY)
        class PostsController < ApplicationController
          def create
            PostService.call(params)
          end
        end
      RUBY

      write_unit('PostService', type: 'service', source_code: <<~RUBY)
        class PostService
          def call
            Post.create!(params)
          end
        end
      RUBY

      stub_graph_defaults
      allow(graph).to receive(:node_exists?).with('PostService').and_return(true)

      assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
      flow = assembler.assemble('PostsController#create')

      expect(flow.steps.size).to eq(2)
      expect(flow.steps[1][:unit]).to eq('PostService')
    end

    it 'detects cycles and emits cycle markers' do
      write_unit('ServiceA', type: 'service', source_code: <<~RUBY)
        class ServiceA
          def call
            ServiceB.call
          end
        end
      RUBY

      write_unit('ServiceB', type: 'service', source_code: <<~RUBY)
        class ServiceB
          def call
            ServiceA.call
          end
        end
      RUBY

      stub_graph_defaults
      allow(graph).to receive(:node_exists?).with('ServiceA').and_return(true)
      allow(graph).to receive(:node_exists?).with('ServiceB').and_return(true)

      assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
      flow = assembler.assemble('ServiceA')

      # Should have ServiceA, ServiceB, and a cycle marker
      types = flow.steps.map { |s| s[:type] }
      expect(types).to include('cycle')

      cycle_step = flow.steps.find { |s| s[:type] == 'cycle' }
      expect(cycle_step[:unit]).to eq('ServiceA')
    end

    it 'respects max_depth limit' do
      write_unit('A', type: 'service', source_code: <<~RUBY)
        class A
          def call
            B.call
          end
        end
      RUBY

      write_unit('B', type: 'service', source_code: <<~RUBY)
        class B
          def call
            C.call
          end
        end
      RUBY

      write_unit('C', type: 'service', source_code: <<~RUBY)
        class C
          def call
            D.call
          end
        end
      RUBY

      stub_graph_defaults
      allow(graph).to receive(:node_exists?).with('B').and_return(true)
      allow(graph).to receive(:node_exists?).with('C').and_return(true)

      assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
      flow = assembler.assemble('A', max_depth: 1)

      # Should expand A (depth 0) and B (depth 1), but not C (depth 2)
      unit_names = flow.steps.map { |s| s[:unit] }
      expect(unit_names).to include('A')
      expect(unit_names).to include('B')
      expect(unit_names).not_to include('C')
    end

    it 'prepends before_action callbacks for controllers' do
      write_unit('PostsController',
                 type: 'controller',
                 source_code: <<~RUBY,
                   class PostsController < ApplicationController
                     def create
                       Post.create!(params)
                     end
                   end
                 RUBY
                 metadata: {
                   'callbacks' => [
                     { 'kind' => 'before', 'name' => 'authenticate_user!' },
                     { 'kind' => 'before', 'name' => 'set_post', 'only' => %w[show update] },
                     { 'kind' => 'after', 'name' => 'log_action' }
                   ]
                 })

      stub_graph_defaults

      assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
      flow = assembler.assemble('PostsController#create')

      ops = flow.steps[0][:operations]
      # authenticate_user! should be prepended (no :only filter)
      callback_ops = ops.select { |o| o[:method] == 'authenticate_user!' }
      expect(callback_ops.size).to eq(1)

      # set_post should NOT be prepended (only: [show, update], not create)
      set_post_ops = ops.select { |o| o[:method] == 'set_post' }
      expect(set_post_ops).to be_empty

      # after callbacks should NOT be prepended
      after_ops = ops.select { |o| o[:method] == 'log_action' }
      expect(after_ops).to be_empty
    end

    it 'prepends filters using :filter key from controller metadata' do
      write_unit('OrdersController',
                 type: 'controller',
                 source_code: <<~RUBY,
                   class OrdersController < ApplicationController
                     def create
                       Order.create!(params)
                     end
                   end
                 RUBY
                 metadata: {
                   'filters' => [
                     { 'kind' => 'before', 'filter' => 'authenticate_user!' },
                     { 'kind' => 'before', 'filter' => 'set_order', 'only' => %w[show update] },
                     { 'kind' => 'after', 'filter' => 'track_event' }
                   ]
                 })

      stub_graph_defaults

      assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
      flow = assembler.assemble('OrdersController#create')

      ops = flow.steps[0][:operations]
      # authenticate_user! should be prepended (no :only filter)
      callback_ops = ops.select { |o| o[:method] == 'authenticate_user!' }
      expect(callback_ops.size).to eq(1)

      # set_order should NOT be prepended (only: [show, update], not create)
      set_order_ops = ops.select { |o| o[:method] == 'set_order' }
      expect(set_order_ops).to be_empty

      # after callbacks should NOT be prepended
      after_ops = ops.select { |o| o[:method] == 'track_event' }
      expect(after_ops).to be_empty
    end

    it 'extracts route information from metadata' do
      write_unit('PostsController',
                 type: 'controller',
                 source_code: <<~RUBY,
                   class PostsController < ApplicationController
                     def create
                       render_created(post)
                     end
                   end
                 RUBY
                 metadata: {
                   'routes' => [
                     { 'action' => 'index', 'verb' => 'GET', 'path' => '/posts' },
                     { 'action' => 'create', 'verb' => 'POST', 'path' => '/posts' }
                   ]
                 })

      stub_graph_defaults

      assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
      flow = assembler.assemble('PostsController#create')

      expect(flow.route).to eq({ verb: 'POST', path: '/posts' })
    end

    it 'returns nil route when no route data exists' do
      write_unit('SomeService', type: 'service', source_code: <<~RUBY)
        class SomeService
          def call
            do_work
          end
        end
      RUBY

      stub_graph_defaults

      assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
      flow = assembler.assemble('SomeService')

      expect(flow.route).to be_nil
    end

    it 'handles missing unit files gracefully' do
      stub_graph_defaults

      assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
      flow = assembler.assemble('NonExistent#method')

      expect(flow.steps).to be_empty
    end

    it 'handles units with no source code' do
      write_unit('EmptyController', source_code: '')

      stub_graph_defaults

      assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
      flow = assembler.assemble('EmptyController#create')

      expect(flow.steps).to be_empty
    end

    describe 'target resolution' do
      it 'resolves targets via graph-wide node existence (tier 1)' do
        write_unit('PostsController', source_code: <<~RUBY)
          class PostsController < ApplicationController
            def create
              PostService.call(params)
            end
          end
        RUBY

        write_unit('PostService', type: 'service', source_code: <<~RUBY)
          class PostService
            def call
              do_work
            end
          end
        RUBY

        stub_graph_defaults
        # PostService is a known node in the graph (tier 1 succeeds)
        allow(graph).to receive(:node_exists?).with('PostService').and_return(true)

        assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
        flow = assembler.assemble('PostsController#create')

        expect(flow.steps.size).to eq(2)
        expect(flow.steps[1][:unit]).to eq('PostService')
      end

      it 'resolves targets via suffix match in the graph (tier 1 suffix)' do
        write_unit('PostsController', source_code: <<~RUBY)
          class PostsController < ApplicationController
            def create
              Update.call(params)
            end
          end
        RUBY

        write_unit('Order::Update', type: 'service', source_code: <<~RUBY)
          class Order::Update
            def call
              do_work
            end
          end
        RUBY

        stub_graph_defaults
        # Exact match misses, but suffix match finds Order::Update
        allow(graph).to receive(:find_node_by_suffix).with('Update').and_return('Order::Update')

        assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
        flow = assembler.assemble('PostsController#create')

        expect(flow.steps.size).to eq(2)
        expect(flow.steps[1][:unit]).to eq('Order::Update')
      end

      it 'resolves targets via disk fallback when not in graph (tier 2)' do
        write_unit('PostsController', source_code: <<~RUBY)
          class PostsController < ApplicationController
            def create
              PostService.call(params)
            end
          end
        RUBY

        write_unit('PostService', type: 'service', source_code: <<~RUBY)
          class PostService
            def call
              do_work
            end
          end
        RUBY

        # Tier 1 (graph) doesn't have PostService — falls through to disk
        stub_graph_defaults

        assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
        flow = assembler.assemble('PostsController#create')

        # Tier 3 finds the JSON on disk and expands
        expect(flow.steps.size).to eq(2)
        expect(flow.steps[1][:unit]).to eq('PostService')
      end

      it 'stops expansion when target is not found in any tier' do
        write_unit('PostsController', source_code: <<~RUBY)
          class PostsController < ApplicationController
            def create
              NonExistentService.call(params)
            end
          end
        RUBY

        stub_graph_defaults

        assembler = described_class.new(graph: graph, extracted_dir: extracted_dir)
        flow = assembler.assemble('PostsController#create')

        # Only the controller step — NonExistentService is nowhere
        expect(flow.steps.size).to eq(1)
        expect(flow.steps[0][:unit]).to eq('PostsController#create')
      end
    end
  end
end
