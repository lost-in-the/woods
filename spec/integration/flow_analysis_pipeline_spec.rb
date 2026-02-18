# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/ast'
require 'codebase_index/flow_analysis/operation_extractor'
require 'codebase_index/flow_analysis/response_code_mapper'
require 'codebase_index/flow_assembler'
require 'codebase_index/flow_document'
require 'codebase_index/dependency_graph'
require 'tmpdir'
require 'json'

RSpec.describe 'Flow Analysis Pipeline', :integration do
  let(:parser) { CodebaseIndex::Ast::Parser.new }
  let(:method_extractor) { CodebaseIndex::Ast::MethodExtractor.new(parser: parser) }
  let(:operation_extractor) { CodebaseIndex::FlowAnalysis::OperationExtractor.new }
  let(:fixtures_dir) { File.expand_path('../fixtures/integration/ruby_sources', __dir__) }

  describe 'OperationExtractor on parsed AST' do
    context 'with controller action source' do
      let(:source) { File.read(File.join(fixtures_dir, 'controller_action.rb')) }

      it 'extracts conditional containing call, response, and async operations from create action' do
        method_node = method_extractor.extract_method(source, 'create')
        expect(method_node).not_to be_nil

        ops = operation_extractor.extract(method_node)

        # The create action is an if/else, so operations are nested in conditional branches
        conditional = ops.find { |o| o[:type] == :conditional }
        expect(conditional).not_to be_nil

        all_branch_ops = (conditional[:then_ops] || []) + (conditional[:else_ops] || [])
        branch_types = all_branch_ops.map { |o| o[:type] }
        expect(branch_types).to include(:call)
        expect(branch_types).to include(:response)
        expect(branch_types).to include(:async)
      end

      it 'extracts render with status codes from create action branches' do
        method_node = method_extractor.extract_method(source, 'create')
        ops = operation_extractor.extract(method_node)

        conditional = ops.find { |o| o[:type] == :conditional }
        all_branch_ops = (conditional[:then_ops] || []) + (conditional[:else_ops] || [])

        response_ops = all_branch_ops.select { |o| o[:type] == :response }
        expect(response_ops).not_to be_empty

        statuses = response_ops.map { |o| o[:status_code] }.compact
        expect(statuses).to include(201) # render json: order, status: :created
      end

      it 'extracts head :no_content from destroy action' do
        method_node = method_extractor.extract_method(source, 'destroy')
        ops = operation_extractor.extract(method_node)

        response_ops = ops.select { |o| o[:type] == :response }
        head_op = response_ops.find { |o| o[:render_method] == 'head' }
        expect(head_op).not_to be_nil
        expect(head_op[:status_code]).to eq(204)
      end

      it 'detects async job enqueue inside create action conditional' do
        method_node = method_extractor.extract_method(source, 'create')
        ops = operation_extractor.extract(method_node)

        conditional = ops.find { |o| o[:type] == :conditional }
        then_ops = conditional[:then_ops] || []

        async_ops = then_ops.select { |o| o[:type] == :async }
        expect(async_ops).not_to be_empty
        expect(async_ops.first[:target]).to eq('NotificationJob')
        expect(async_ops.first[:method]).to eq('perform_later')
      end

      it 'extracts conditional structure from create action' do
        method_node = method_extractor.extract_method(source, 'create')
        ops = operation_extractor.extract(method_node)

        conditional_ops = ops.select { |o| o[:type] == :conditional }
        expect(conditional_ops).not_to be_empty

        cond = conditional_ops.first
        expect(cond[:kind]).to eq('if')
        expect(cond[:then_ops]).to be_an(Array)
        expect(cond[:else_ops]).to be_an(Array)
      end
    end

    context 'with service source' do
      let(:source) { File.read(File.join(fixtures_dir, 'service_with_flow.rb')) }

      it 'extracts call operations from process method' do
        method_node = method_extractor.extract_method(source, 'process')
        ops = operation_extractor.extract(method_node)

        call_ops = ops.select { |o| o[:type] == :call }
        targets = call_ops.map { |o| o[:target] }
        expect(targets).to include('Gateway')
      end

      it 'extracts conditional with then and else branch operations' do
        method_node = method_extractor.extract_method(source, 'process')
        ops = operation_extractor.extract(method_node)

        conditional = ops.find { |o| o[:type] == :conditional }
        expect(conditional).not_to be_nil

        then_targets = conditional[:then_ops].select { |o| o[:type] == :call }.map { |o| o[:target] }
        else_targets = conditional[:else_ops].select { |o| o[:type] == :call }.map { |o| o[:target] }

        # ReceiptMailer.send_receipt(order).deliver_later is a chain — target is the receiver chain
        expect(then_targets.any? { |t| t&.include?('ReceiptMailer') }).to be true
        expect(else_targets).to include('ErrorTracker')
      end

      it 'extracts async job enqueue from process rescue block' do
        method_node = method_extractor.extract_method(source, 'process')
        ops = operation_extractor.extract(method_node)

        async_ops = ops.select { |o| o[:type] == :async }
        expect(async_ops).not_to be_empty
        expect(async_ops.first[:target]).to eq('RetryJob')
      end

      it 'extracts transaction wrapper from refund method' do
        method_node = method_extractor.extract_method(source, 'refund')
        ops = operation_extractor.extract(method_node)

        transaction_ops = ops.select { |o| o[:type] == :transaction }
        expect(transaction_ops).not_to be_empty

        txn = transaction_ops.first
        expect(txn[:nested]).to be_an(Array)
        expect(txn[:nested]).not_to be_empty

        nested_targets = txn[:nested].select { |o| o[:type] == :call }.map { |o| o[:target] }
        expect(nested_targets).to include('Gateway')
        expect(nested_targets).to include('AuditLog')
      end
    end
  end

  describe 'ResponseCodeMapper integration' do
    it 'resolves render status: :created from parsed AST arguments' do
      source = <<~RUBY
        def create
          render json: order, status: :created
        end
      RUBY

      method_node = method_extractor.extract_method(source, 'create')
      ops = operation_extractor.extract(method_node)

      response = ops.find { |o| o[:type] == :response }
      expect(response).not_to be_nil
      expect(response[:status_code]).to eq(201)
    end

    it 'resolves head :no_content from parsed AST' do
      source = <<~RUBY
        def destroy
          head :no_content
        end
      RUBY

      method_node = method_extractor.extract_method(source, 'destroy')
      ops = operation_extractor.extract(method_node)

      response = ops.find { |o| o[:type] == :response }
      expect(response[:status_code]).to eq(204)
    end

    it 'resolves redirect_to as 302 from parsed AST' do
      source = <<~RUBY
        def update
          redirect_to root_path
        end
      RUBY

      method_node = method_extractor.extract_method(source, 'update')
      ops = operation_extractor.extract(method_node)

      response = ops.find { |o| o[:type] == :response }
      expect(response[:status_code]).to eq(302)
    end

    it 'resolves render_created convention from parsed AST' do
      source = <<~RUBY
        def create
          render_created(result)
        end
      RUBY

      method_node = method_extractor.extract_method(source, 'create')
      ops = operation_extractor.extract(method_node)

      response = ops.find { |o| o[:type] == :response }
      expect(response[:status_code]).to eq(201)
    end
  end

  describe 'FlowAssembler end-to-end with real parsing' do
    let(:extracted_dir) { Dir.mktmpdir('flow_pipeline_test') }
    let(:graph) { CodebaseIndex::DependencyGraph.new }

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
      type_dir = File.join(extracted_dir, "#{type}s")
      FileUtils.mkdir_p(type_dir)
      filename = "#{identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')}.json"
      File.write(File.join(type_dir, filename), JSON.generate(data))
    end

    it 'assembles a flow from controller through service with real AST parsing' do
      controller_source = File.read(File.join(fixtures_dir, 'controller_action.rb'))
      service_source = File.read(File.join(fixtures_dir, 'service_with_flow.rb'))

      write_unit('OrdersController', source_code: controller_source, type: 'controller')
      write_unit('PaymentProcessor', source_code: service_source, type: 'service')

      # Wire up the dependency graph with real units
      controller_unit = CodebaseIndex::ExtractedUnit.new(
        type: :controller,
        identifier: 'OrdersController',
        file_path: 'app/controllers/orders_controller.rb'
      )
      controller_unit.dependencies = [{ type: :service, target: 'PaymentProcessor', via: :method_call }]

      service_unit = CodebaseIndex::ExtractedUnit.new(
        type: :service,
        identifier: 'PaymentProcessor',
        file_path: 'app/services/payment_processor.rb'
      )

      graph.register(controller_unit)
      graph.register(service_unit)

      assembler = CodebaseIndex::FlowAssembler.new(graph: graph, extracted_dir: extracted_dir)
      flow = assembler.assemble('OrdersController#create')

      expect(flow).to be_a(CodebaseIndex::FlowDocument)
      expect(flow.entry_point).to eq('OrdersController#create')
      expect(flow.steps.size).to be >= 1

      # First step is the controller
      expect(flow.steps[0][:unit]).to eq('OrdersController#create')

      # Controller step should have operations
      controller_ops = flow.steps[0][:operations]
      expect(controller_ops).not_to be_empty
    end

    it 'produces a valid FlowDocument that serializes to hash and markdown' do
      controller_source = File.read(File.join(fixtures_dir, 'controller_action.rb'))

      write_unit('OrdersController',
                 source_code: controller_source,
                 type: 'controller',
                 metadata: {
                   'routes' => [
                     { 'action' => 'create', 'verb' => 'POST', 'path' => '/orders' }
                   ]
                 })

      assembler = CodebaseIndex::FlowAssembler.new(graph: graph, extracted_dir: extracted_dir)
      flow = assembler.assemble('OrdersController#create')

      # to_h round-trip
      hash = flow.to_h
      expect(hash[:entry_point]).to eq('OrdersController#create')
      expect(hash[:steps]).to be_an(Array)
      expect(hash[:generated_at]).to match(/\d{4}-\d{2}-\d{2}/)

      # FlowDocument.from_h round-trip
      restored = CodebaseIndex::FlowDocument.from_h(hash)
      expect(restored.entry_point).to eq(flow.entry_point)
      expect(restored.steps.size).to eq(flow.steps.size)

      # Markdown rendering
      markdown = flow.to_markdown
      expect(markdown).to include('OrdersController#create')
      expect(markdown).to be_a(String)
      expect(markdown.length).to be > 0
    end

    it 'extracts route info from controller metadata' do
      controller_source = File.read(File.join(fixtures_dir, 'controller_action.rb'))

      write_unit('OrdersController',
                 source_code: controller_source,
                 type: 'controller',
                 metadata: {
                   'routes' => [
                     { 'action' => 'index', 'verb' => 'GET', 'path' => '/orders' },
                     { 'action' => 'create', 'verb' => 'POST', 'path' => '/orders' }
                   ]
                 })

      assembler = CodebaseIndex::FlowAssembler.new(graph: graph, extracted_dir: extracted_dir)
      flow = assembler.assemble('OrdersController#create')

      expect(flow.route).to eq({ verb: 'POST', path: '/orders' })
    end
  end
end
