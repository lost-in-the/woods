# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/ast'
require 'codebase_index/ruby_analyzer/class_analyzer'
require 'codebase_index/ruby_analyzer/method_analyzer'
require 'codebase_index/ruby_analyzer/dataflow_analyzer'

RSpec.describe 'Static Analysis Pipeline', :integration do
  let(:parser) { CodebaseIndex::Ast::Parser.new }
  let(:class_analyzer) { CodebaseIndex::RubyAnalyzer::ClassAnalyzer.new(parser: parser) }
  let(:method_analyzer) { CodebaseIndex::RubyAnalyzer::MethodAnalyzer.new(parser: parser) }
  let(:dataflow_analyzer) { CodebaseIndex::RubyAnalyzer::DataFlowAnalyzer.new(parser: parser) }

  let(:fixtures_dir) { File.expand_path('../fixtures/integration/ruby_sources', __dir__) }

  describe 'complex model through full pipeline' do
    let(:source) { File.read(File.join(fixtures_dir, 'complex_model.rb')) }
    let(:file_path) { '/app/models/order.rb' }

    it 'ClassAnalyzer extracts the class with superclass, mixins, and constants' do
      units = class_analyzer.analyze(source: source, file_path: file_path)

      class_unit = units.find { |u| u.type == :ruby_class }
      expect(class_unit).not_to be_nil
      expect(class_unit.identifier).to eq('Order')
      expect(class_unit.metadata[:superclass]).to eq('ApplicationRecord')
      expect(class_unit.metadata[:includes]).to include('Auditable')
      expect(class_unit.metadata[:extends]).to include('Searchable')
      expect(class_unit.metadata[:constants]).to include('STATUSES', 'MAX_ITEMS')
    end

    it 'ClassAnalyzer records inheritance and mixin dependencies' do
      units = class_analyzer.analyze(source: source, file_path: file_path)
      class_unit = units.find { |u| u.type == :ruby_class }

      expect(class_unit.dependencies).to include(
        a_hash_including(target: 'ApplicationRecord', via: :inheritance)
      )
      expect(class_unit.dependencies).to include(
        a_hash_including(target: 'Auditable', via: :include)
      )
      expect(class_unit.dependencies).to include(
        a_hash_including(target: 'Searchable', via: :extend)
      )
    end

    it 'MethodAnalyzer extracts instance and class methods with visibility' do
      units = method_analyzer.analyze(source: source, file_path: file_path)

      public_methods = units.select { |u| u.metadata[:visibility] == :public }
      private_methods = units.select { |u| u.metadata[:visibility] == :private }

      public_ids = public_methods.map(&:identifier)
      private_ids = private_methods.map(&:identifier)

      expect(public_ids).to include('Order#confirm!', 'Order#cancel!')
      expect(private_ids).to include('Order#recalculate_total', 'Order#notify_warehouse')
    end

    it 'MethodAnalyzer extracts class methods with separator' do
      units = method_analyzer.analyze(source: source, file_path: file_path)

      class_method = units.find { |u| u.identifier == 'Order.find_by_reference' }
      expect(class_method).not_to be_nil
      expect(class_method.type).to eq(:ruby_method)
    end

    it 'MethodAnalyzer detects cross-class call graph dependencies' do
      units = method_analyzer.analyze(source: source, file_path: file_path)

      confirm_method = units.find { |u| u.identifier == 'Order#confirm!' }
      expect(confirm_method).not_to be_nil
      expect(confirm_method.metadata[:call_graph]).to include(
        a_hash_including(target: 'OrderMailer')
      )
      expect(confirm_method.dependencies).to include(
        a_hash_including(target: 'OrderMailer', via: :method_call)
      )
    end

    it 'DataFlowAnalyzer annotates method units with transformation metadata' do
      method_units = method_analyzer.analyze(source: source, file_path: file_path)
      dataflow_analyzer.annotate(method_units)

      method_units.each do |unit|
        expect(unit.metadata).to have_key(:data_transformations)
        expect(unit.metadata[:data_transformations]).to be_an(Array)
      end
    end

    it 'full pipeline: parse → class analyze → method analyze → dataflow annotate' do
      class_units = class_analyzer.analyze(source: source, file_path: file_path)
      method_units = method_analyzer.analyze(source: source, file_path: file_path)
      dataflow_analyzer.annotate(method_units)

      all_units = class_units + method_units

      # We get both structural (class) and behavioral (method) units
      types = all_units.map(&:type).uniq
      expect(types).to include(:ruby_class, :ruby_method)

      # Every unit has required fields
      all_units.each do |unit|
        expect(unit.identifier).not_to be_empty
        expect(unit.file_path).to eq(file_path)
        expect(unit.type).not_to be_nil
      end

      # Method units have dataflow annotations
      method_units.each do |unit|
        expect(unit.metadata[:data_transformations]).to be_an(Array)
      end
    end
  end

  describe 'service object through full pipeline' do
    let(:source) { File.read(File.join(fixtures_dir, 'service_with_flow.rb')) }
    let(:file_path) { '/app/services/payment_processor.rb' }

    it 'ClassAnalyzer extracts the service class without superclass' do
      units = class_analyzer.analyze(source: source, file_path: file_path)

      class_unit = units.find { |u| u.type == :ruby_class }
      expect(class_unit.identifier).to eq('PaymentProcessor')
      expect(class_unit.metadata[:superclass]).to be_nil
    end

    it 'MethodAnalyzer extracts methods with call graph showing external dependencies' do
      units = method_analyzer.analyze(source: source, file_path: file_path)

      process_method = units.find { |u| u.identifier == 'PaymentProcessor#process' }
      expect(process_method).not_to be_nil

      targets = process_method.metadata[:call_graph].map { |c| c[:target] }
      expect(targets).to include('Gateway')
      expect(targets).to include('ErrorTracker')
    end

    it 'DataFlowAnalyzer detects no serialization in a service without to_json/to_h' do
      method_units = method_analyzer.analyze(source: source, file_path: file_path)
      dataflow_analyzer.annotate(method_units)

      # The refund method calls Gateway.refund and AuditLog.record but no serialization
      refund_method = method_units.find { |u| u.identifier == 'PaymentProcessor#refund' }
      serialization_ops = refund_method.metadata[:data_transformations].select do |t|
        t[:category] == :serialization
      end
      expect(serialization_ops).to be_empty
    end
  end

  describe 'controller through full pipeline' do
    let(:source) { File.read(File.join(fixtures_dir, 'controller_action.rb')) }
    let(:file_path) { '/app/controllers/orders_controller.rb' }

    it 'ClassAnalyzer extracts the controller class with ApplicationController superclass' do
      units = class_analyzer.analyze(source: source, file_path: file_path)

      class_unit = units.find { |u| u.type == :ruby_class }
      expect(class_unit.identifier).to eq('OrdersController')
      expect(class_unit.metadata[:superclass]).to eq('ApplicationController')
    end

    it 'MethodAnalyzer extracts public actions and private helpers' do
      units = method_analyzer.analyze(source: source, file_path: file_path)

      public_methods = units.select { |u| u.metadata[:visibility] == :public }
      private_methods = units.select { |u| u.metadata[:visibility] == :private }

      expect(public_methods.map(&:identifier)).to include(
        'OrdersController#index',
        'OrdersController#create',
        'OrdersController#destroy'
      )
      expect(private_methods.map(&:identifier)).to include(
        'OrdersController#set_order',
        'OrdersController#order_params'
      )
    end

    it 'MethodAnalyzer detects create action dependencies on PaymentProcessor and NotificationJob' do
      units = method_analyzer.analyze(source: source, file_path: file_path)

      create_method = units.find { |u| u.identifier == 'OrdersController#create' }
      targets = create_method.metadata[:call_graph].map { |c| c[:target] }

      expect(targets).to include('PaymentProcessor')
      expect(targets).to include('NotificationJob')
    end

    it 'DataFlowAnalyzer detects construction in create action' do
      method_units = method_analyzer.analyze(source: source, file_path: file_path)
      dataflow_analyzer.annotate(method_units)

      create_method = method_units.find { |u| u.identifier == 'OrdersController#create' }
      construction = create_method.metadata[:data_transformations].select do |t|
        t[:category] == :construction
      end
      expect(construction).not_to be_empty
      expect(construction.first[:method]).to eq('new')
    end

    it 'produces serializable units across the full pipeline' do
      class_units = class_analyzer.analyze(source: source, file_path: file_path)
      method_units = method_analyzer.analyze(source: source, file_path: file_path)
      dataflow_analyzer.annotate(method_units)

      all_units = class_units + method_units

      all_units.each do |unit|
        hash = unit.to_h
        expect(hash[:type]).not_to be_nil
        expect(hash[:identifier]).to be_a(String)
        expect(hash[:file_path]).to eq(file_path)
        expect(hash[:source_hash]).to be_a(String)
        expect(hash[:extracted_at]).to match(/\d{4}-\d{2}-\d{2}/)
      end
    end
  end

  describe 'shared parser instance consistency' do
    it 'produces identical ASTs when the same parser parses the same source twice' do
      source = File.read(File.join(fixtures_dir, 'complex_model.rb'))
      file_path = '/app/models/order.rb'

      units_a = class_analyzer.analyze(source: source, file_path: file_path)
      units_b = class_analyzer.analyze(source: source, file_path: file_path)

      expect(units_a.map(&:identifier)).to eq(units_b.map(&:identifier))
      expect(units_a.map { |u| u.metadata[:method_count] }).to eq(
        units_b.map { |u| u.metadata[:method_count] }
      )
    end
  end
end
