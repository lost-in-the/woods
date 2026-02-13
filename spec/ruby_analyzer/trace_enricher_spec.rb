# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'codebase_index/ruby_analyzer/trace_enricher'

RSpec.describe CodebaseIndex::RubyAnalyzer::TraceEnricher do
  def make_unit(identifier:, type: :ruby_method)
    unit = CodebaseIndex::ExtractedUnit.new(
      type: type,
      identifier: identifier,
      file_path: '/app/greeter.rb'
    )
    unit.source_code = 'def example; end'
    unit.metadata = {}
    unit
  end

  describe '.record' do
    it 'captures trace data from a block' do
      trace_data = described_class.record do
        # Define and call a simple method
        obj = Object.new
        def obj.test_method
          42
        end
        obj.test_method
      end

      expect(trace_data).to be_an(Array)
      expect(trace_data).not_to be_empty
      expect(trace_data.first).to have_key(:class_name)
      expect(trace_data.first).to have_key(:method_name)
      expect(trace_data.first).to have_key(:event)
    end

    it 'captures call and return events' do
      trace_data = described_class.record do
        obj = Object.new
        def obj.traced_call
          "result"
        end
        obj.traced_call
      end

      events = trace_data.map { |t| t[:event] }
      expect(events).to include('call')
      expect(events).to include('return')
    end
  end

  describe '.merge' do
    let(:fixture_path) { File.join(__dir__, '..', 'fixtures', 'trace_data.json') }
    let(:trace_data) { JSON.parse(File.read(fixture_path))['traces'] }

    it 'enriches matching method units with trace metadata' do
      unit = make_unit(identifier: 'Greeter#greet')

      described_class.merge(units: [unit], trace_data: trace_data)

      expect(unit.metadata[:trace]).to be_a(Hash)
      expect(unit.metadata[:trace][:call_count]).to be >= 1
      expect(unit.metadata[:trace][:callers]).to include(
        a_hash_including('caller_class' => 'Main', 'caller_method' => 'run')
      )
    end

    it 'records return types from trace data' do
      unit = make_unit(identifier: 'Greeter#greet')

      described_class.merge(units: [unit], trace_data: trace_data)

      expect(unit.metadata[:trace][:return_types]).to include('String')
    end

    it 'does not modify units without matching traces' do
      unit = make_unit(identifier: 'Unrelated#method')

      described_class.merge(units: [unit], trace_data: trace_data)

      expect(unit.metadata[:trace]).to be_nil
    end

    it 'handles empty trace data' do
      unit = make_unit(identifier: 'Greeter#greet')

      described_class.merge(units: [unit], trace_data: [])

      expect(unit.metadata[:trace]).to be_nil
    end

    it 'handles class method identifiers' do
      trace = [{
        'class_name' => 'Factory',
        'method_name' => 'build',
        'event' => 'call',
        'path' => '/app/factory.rb',
        'line' => 1,
        'caller_class' => 'Test',
        'caller_method' => 'run'
      }]

      unit = make_unit(identifier: 'Factory.build')

      described_class.merge(units: [unit], trace_data: trace)

      expect(unit.metadata[:trace]).to be_a(Hash)
      expect(unit.metadata[:trace][:call_count]).to eq(1)
    end

    it 'aggregates multiple call traces for the same method' do
      traces = [
        { 'class_name' => 'Foo', 'method_name' => 'bar', 'event' => 'call',
          'caller_class' => 'A', 'caller_method' => 'x' },
        { 'class_name' => 'Foo', 'method_name' => 'bar', 'event' => 'call',
          'caller_class' => 'B', 'caller_method' => 'y' },
        { 'class_name' => 'Foo', 'method_name' => 'bar', 'event' => 'return',
          'return_class' => 'Integer' }
      ]

      unit = make_unit(identifier: 'Foo#bar')

      described_class.merge(units: [unit], trace_data: traces)

      expect(unit.metadata[:trace][:call_count]).to eq(2)
      expect(unit.metadata[:trace][:callers].size).to eq(2)
    end
  end
end
