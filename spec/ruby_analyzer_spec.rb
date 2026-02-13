# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/ruby_analyzer'

RSpec.describe CodebaseIndex::RubyAnalyzer do
  describe '.analyze' do
    it 'returns an array of ExtractedUnit objects' do
      path = File.expand_path('../lib/codebase_index/extracted_unit.rb', __dir__)
      units = described_class.analyze(paths: [path])

      expect(units).to be_an(Array)
      expect(units).not_to be_empty
      expect(units).to all(be_a(CodebaseIndex::ExtractedUnit))
    end

    it 'produces class units' do
      path = File.expand_path('../lib/codebase_index/extracted_unit.rb', __dir__)
      units = described_class.analyze(paths: [path])

      class_units = units.select { |u| u.type == :ruby_class }
      expect(class_units).not_to be_empty
      expect(class_units.map(&:identifier)).to include('CodebaseIndex::ExtractedUnit')
    end

    it 'produces module units' do
      path = File.expand_path('../lib/codebase_index/extracted_unit.rb', __dir__)
      units = described_class.analyze(paths: [path])

      module_units = units.select { |u| u.type == :ruby_module }
      expect(module_units.map(&:identifier)).to include('CodebaseIndex')
    end

    it 'produces method units' do
      path = File.expand_path('../lib/codebase_index/extracted_unit.rb', __dir__)
      units = described_class.analyze(paths: [path])

      method_units = units.select { |u| u.type == :ruby_method }
      expect(method_units).not_to be_empty
      identifiers = method_units.map(&:identifier)
      expect(identifiers).to include('CodebaseIndex::ExtractedUnit#to_h')
      expect(identifiers).to include('CodebaseIndex::ExtractedUnit#estimated_tokens')
    end

    it 'annotates units with data transformations' do
      path = File.expand_path('../lib/codebase_index/extracted_unit.rb', __dir__)
      units = described_class.analyze(paths: [path])

      # At least some units should have data_transformations metadata
      annotated = units.select { |u| u.metadata.key?(:data_transformations) }
      expect(annotated).not_to be_empty
    end

    it 'accepts trace_data for enrichment' do
      path = File.expand_path('../lib/codebase_index/extracted_unit.rb', __dir__)
      trace_data = [
        { 'class_name' => 'CodebaseIndex::ExtractedUnit', 'method_name' => 'to_h',
          'event' => 'call', 'caller_class' => 'Test', 'caller_method' => 'run' }
      ]

      units = described_class.analyze(paths: [path], trace_data: trace_data)

      to_h_unit = units.find { |u| u.identifier == 'CodebaseIndex::ExtractedUnit#to_h' }
      expect(to_h_unit.metadata[:trace]).to be_a(Hash)
    end

    it 'handles non-existent paths gracefully' do
      units = described_class.analyze(paths: ['/nonexistent/file.rb'])

      expect(units).to eq([])
    end

    it 'handles empty paths list' do
      units = described_class.analyze(paths: [])

      expect(units).to eq([])
    end

    it 'discovers .rb files from directories' do
      dir = File.expand_path('../lib/codebase_index/ast', __dir__)
      units = described_class.analyze(paths: [dir])

      expect(units).not_to be_empty
      # Should have found classes from ast directory files
      identifiers = units.map(&:identifier)
      expect(identifiers).to include('CodebaseIndex::Ast::Parser')
    end

    it 'processes multiple files' do
      paths = [
        File.expand_path('../lib/codebase_index/extracted_unit.rb', __dir__),
        File.expand_path('../lib/codebase_index/dependency_graph.rb', __dir__)
      ]
      units = described_class.analyze(paths: paths)

      identifiers = units.map(&:identifier)
      expect(identifiers).to include('CodebaseIndex::ExtractedUnit')
      expect(identifiers).to include('CodebaseIndex::DependencyGraph')
    end
  end
end
