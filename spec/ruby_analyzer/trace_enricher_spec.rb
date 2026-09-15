# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'timeout'
require 'open3'
require 'woods/ruby_analyzer/trace_enricher'
require_relative '../fixtures/trace_callers'

RSpec.describe Woods::RubyAnalyzer::TraceEnricher do
  def make_unit(identifier:, type: :ruby_method)
    unit = Woods::ExtractedUnit.new(
      type: type,
      identifier: identifier,
      file_path: '/app/greeter.rb'
    )
    unit.source_code = 'def example; end'
    unit.metadata = {}
    unit
  end

  describe '.record' do
    it 'records and merges the observed calling method instead of the callee' do
      caller = TraceCallerFixture::Caller.new
      callee = TraceCallerFixture::Callee.new
      traces = described_class.record { caller.invoke(callee) }
      calls = traces.select { |event| event[:class_name] == callee.class.name && event[:method_name] == 'run' }

      expect(calls.size).to eq(2)
      expect(calls).to all(include(caller_class: caller.class.name, caller_method: 'invoke'))
      unit = make_unit(identifier: 'TraceCallerFixture::Callee#run')
      described_class.merge(units: [unit], trace_data: traces)
      expected = { 'caller_class' => 'TraceCallerFixture::Caller', 'caller_method' => 'invoke' }
      expect(unit.metadata[:trace][:callers]).to eq([expected])
    end

    it 'leaves callers outside the recording window unknown' do
      traces = TraceCallerFixture::Caller.new.record_inside(described_class, TraceCallerFixture::Callee.new)
      events = traces.select { |event| event[:method_name] == 'run' }

      expect(events.size).to eq(2)
      expect(events).to all(include(caller_class: nil, caller_method: nil))
    end

    it 'balances recursive frames and does not retain a caller after they return' do
      callee = TraceCallerFixture::Callee.new
      traces = described_class.record do
        callee.recurse(2)
        callee.run
      end
      recursion = traces.select { |event| event[:method_name] == 'recurse' }
      callers = recursion.map { |event| event[:caller_method] }
      expect(callers).to eq([nil, 'recurse', 'recurse', 'recurse', 'recurse', nil])
      run_callers = traces.select { |event| event[:method_name] == 'run' && event[:event] == 'call' }
      expect(run_callers.map { |event| event[:caller_method] }).to eq(['recurse', nil])
    end

    it 'restores the surviving caller after an exception unwinds nested calls' do
      caller = TraceCallerFixture::Caller.new
      callee = TraceCallerFixture::Callee.new
      traces = described_class.record { caller.recover(callee) }
      calls = traces.select { |event| event[:method_name] == 'run' }

      expect(calls.size).to eq(2)
      expect(calls).to all(include(caller_class: caller.class.name, caller_method: 'recover'))
      unwound = traces.find { |event| event[:method_name] == 'explode' && event[:event] == 'return' }
      expect(unwound).to include(caller_class: caller.class.name, caller_method: 'unwind')
    end

    it 'balances a nonlocal throw before recording the next call' do
      caller = TraceCallerFixture::Caller.new
      callee = TraceCallerFixture::Callee.new
      traces = described_class.record { caller.catch_throw(callee) }
      events = traces.select { |event| event[:method_name] == 'run' }

      expect(events.size).to eq(2)
      expect(events).to all(include(caller_class: caller.class.name, caller_method: 'catch_throw'))
    end

    it 'isolates interleaved fibers and resumes each recorded caller' do
      callee = TraceCallerFixture::Callee.new
      first = Fiber.new { TraceCallerFixture::Caller.new.pause_and_invoke(callee) }
      second = Fiber.new { TraceCallerFixture::OtherCaller.new.invoke(callee) }
      traces = described_class.record do
        first.resume
        second.resume
        first.resume
        callee.run
      end
      calls = traces.select { |event| event[:method_name] == 'run' && event[:event] == 'call' }

      expected = [
        ['TraceCallerFixture::OtherCaller', 'invoke'],
        ['TraceCallerFixture::Caller', 'pause_and_invoke'],
        [nil, nil]
      ]
      expect(calls.map { |event| event.values_at(:caller_class, :caller_method) }).to eq(expected)
    end

    it 'handles returns from a fiber method entered before recording began' do
      callee = TraceCallerFixture::Callee.new
      caller = TraceCallerFixture::Caller.new
      fiber = Fiber.new { caller.pause_and_invoke(callee) }
      fiber.resume
      traces = described_class.record do
        fiber.resume
        caller.invoke(callee)
      end
      calls = traces.select { |event| event[:method_name] == 'run' && event[:event] == 'call' }

      expect(calls.map { |event| event[:caller_method] }).to eq([nil, 'invoke'])
      unmatched = traces.find { |event| event[:method_name] == 'pause_and_invoke' }
      expect(unmatched).to include(event: 'return', caller_class: nil, caller_method: nil)
    end

    it 'does not collect another thread into the recording thread stack' do
      callee = TraceCallerFixture::Callee.new
      traces = described_class.record do
        Thread.new { TraceCallerFixture::OtherCaller.new.invoke(callee) }.join
        TraceCallerFixture::Caller.new.invoke(callee)
      end

      expect(traces.none? { |event| event[:class_name] == 'TraceCallerFixture::OtherCaller' }).to be(true)
      calls = traces.select { |event| event[:method_name] == 'run' && event[:event] == 'call' }
      expect(calls.size).to eq(1)
      expect(calls.first).to include(caller_class: 'TraceCallerFixture::Caller', caller_method: 'invoke')
    end

    it 'keeps simultaneously active thread recordings independent' do
      started = Queue.new
      proceed = Queue.new
      callee = TraceCallerFixture::Callee.new
      recorder = described_class
      first = Thread.new do
        recorder.record { TraceCallerFixture::Caller.new.wait_and_invoke(callee, started, proceed) }
      end
      Timeout.timeout(5) { started.pop }
      second = Thread.new { recorder.record { TraceCallerFixture::OtherCaller.new.invoke(callee) } }
      second_trace = Timeout.timeout(5) { second.value }
      proceed << true
      first_trace = Timeout.timeout(5) { first.value }

      [first_trace, second_trace].zip(%w[wait_and_invoke invoke]).each do |traces, method|
        calls = traces.select { |event| event[:method_name] == 'run' && event[:event] == 'call' }
        expect(calls.size).to eq(1)
        expect(calls.first[:caller_method]).to eq(method)
      end
      entry = second_trace.find { |event| event[:class_name] == 'TraceCallerFixture::OtherCaller' }
      expect(entry).to include(caller_class: nil, caller_method: nil)
    ensure
      proceed << true if proceed
      first&.join(5)
      second&.join(5)
    end

    it 'disables the recorder after an escaping exception and starts the next recording empty' do
      created = []
      allow(TracePoint).to receive(:new).and_wrap_original do |original, *events, &callback|
        original.call(*events, &callback).tap { |trace| created << trace }
      end
      callee = TraceCallerFixture::Callee.new
      expect { described_class.record { callee.explode } }.to raise_error(RuntimeError, 'fixture failure')
      expect(created).not_to be_empty
      expect(created.any?(&:enabled?)).to be(false)

      traces = described_class.record { callee.run }
      events = traces.select { |event| event[:method_name] == 'run' }
      expect(events).to all(include(caller_class: nil, caller_method: nil))
    ensure
      created&.each(&:disable)
    end

    it 'loads and records standalone without Rails or the Woods entrypoint' do
      script = <<~RUBY
        require 'json'
        require 'woods/ruby_analyzer/trace_enricher'
        require #{File.expand_path('../fixtures/trace_callers', __dir__).inspect}
        caller = TraceCallerFixture::Caller.new
        callee = TraceCallerFixture::Callee.new
        traces = Woods::RubyAnalyzer::TraceEnricher.record { caller.invoke(callee) }
        puts JSON.generate(traces.select { |event| event[:method_name] == 'run' })
      RUBY
      lib = File.expand_path('../../lib', __dir__)
      out, err, status = Open3.capture3(RbConfig.ruby, '-I', lib, '-e', script)

      expect(status).to be_success, err
      expect(JSON.parse(out)).to all(include('caller_class' => 'TraceCallerFixture::Caller',
                                             'caller_method' => 'invoke'))
    end

    it 'rejects a missing block before creating a trace' do
      traces = []
      allow(TracePoint).to receive(:new).and_wrap_original do |original, *events, &callback|
        original.call(*events, &callback).tap { |trace| traces << trace }
      end

      aggregate_failures do
        expect { described_class.record }.to raise_error(ArgumentError, 'block required')
        expect(traces).to be_empty
        expect(traces.any?(&:enabled?)).to be(false)
      end
    ensure
      traces&.each(&:disable)
    end

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
          'result'
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
