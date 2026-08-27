# frozen_string_literal: true

require 'spec_helper'
require 'woods/ruby_analyzer'

RSpec.describe Woods::RubyAnalyzer do
  describe '.analyze' do
    it 'returns an array of ExtractedUnit objects' do
      path = File.expand_path('../lib/woods/extracted_unit.rb', __dir__)
      units = described_class.analyze(paths: [path])

      expect(units).to be_an(Array)
      expect(units).not_to be_empty
      expect(units).to all(be_a(Woods::ExtractedUnit))
    end

    it 'reads multibyte source as UTF-8 regardless of the default external encoding' do
      # Ruby source defaults to UTF-8. Under LANG=C (US-ASCII default
      # external, how this suite runs in CI) a bare File.read tags an em
      # dash as invalid and JSON generation raises out of the analysis,
      # which is how woods:self_analyze crashed on the gem's own source.
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'dashy.rb')
        File.write(path, <<~RUBY, encoding: Encoding::UTF_8)
          # frozen_string_literal: true

          # A comment with an em dash — multibyte on purpose.
          class Dashy
          end
        RUBY

        units = described_class.analyze(paths: [path])

        expect(units).not_to be_empty
        source = units.first.source_code
        expect(source.encoding).to eq(Encoding::UTF_8)
        expect(source.valid_encoding?).to be(true)
        expect { JSON.generate(units.first.to_h) }.not_to raise_error
      end
    end

    it 'produces class units' do
      path = File.expand_path('../lib/woods/extracted_unit.rb', __dir__)
      units = described_class.analyze(paths: [path])

      class_units = units.select { |u| u.type == :ruby_class }
      expect(class_units).not_to be_empty
      expect(class_units.map(&:identifier)).to include('Woods::ExtractedUnit')
    end

    it 'produces module units' do
      path = File.expand_path('../lib/woods/extracted_unit.rb', __dir__)
      units = described_class.analyze(paths: [path])

      module_units = units.select { |u| u.type == :ruby_module }
      expect(module_units.map(&:identifier)).to include('Woods')
    end

    it 'produces method units' do
      path = File.expand_path('../lib/woods/extracted_unit.rb', __dir__)
      units = described_class.analyze(paths: [path])

      method_units = units.select { |u| u.type == :ruby_method }
      expect(method_units).not_to be_empty
      identifiers = method_units.map(&:identifier)
      expect(identifiers).to include('Woods::ExtractedUnit#to_h')
      expect(identifiers).to include('Woods::ExtractedUnit#estimated_tokens')
    end

    it 'annotates units with data transformations' do
      path = File.expand_path('../lib/woods/extracted_unit.rb', __dir__)
      units = described_class.analyze(paths: [path])

      # At least some units should have data_transformations metadata
      annotated = units.select { |u| u.metadata.key?(:data_transformations) }
      expect(annotated).not_to be_empty
    end

    it 'accepts trace_data for enrichment' do
      path = File.expand_path('../lib/woods/extracted_unit.rb', __dir__)
      trace_data = [
        { 'class_name' => 'Woods::ExtractedUnit', 'method_name' => 'to_h',
          'event' => 'call', 'caller_class' => 'Test', 'caller_method' => 'run' }
      ]

      units = described_class.analyze(paths: [path], trace_data: trace_data)

      to_h_unit = units.find { |u| u.identifier == 'Woods::ExtractedUnit#to_h' }
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
      dir = File.expand_path('../lib/woods/ast', __dir__)
      units = described_class.analyze(paths: [dir])

      expect(units).not_to be_empty
      # Should have found classes from ast directory files
      identifiers = units.map(&:identifier)
      expect(identifiers).to include('Woods::Ast::Parser')
    end

    it 'processes multiple files' do
      paths = [
        File.expand_path('../lib/woods/extracted_unit.rb', __dir__),
        File.expand_path('../lib/woods/dependency_graph.rb', __dir__)
      ]
      units = described_class.analyze(paths: paths)

      identifiers = units.map(&:identifier)
      expect(identifiers).to include('Woods::ExtractedUnit')
      expect(identifiers).to include('Woods::DependencyGraph')
    end
  end
end
