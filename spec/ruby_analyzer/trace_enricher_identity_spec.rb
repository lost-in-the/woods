# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'woods/ruby_analyzer'
require_relative '../fixtures/trace_kind_fixture'

RSpec.describe Woods::RubyAnalyzer::TraceEnricher do
  def unit(identifier)
    Woods::ExtractedUnit.new(type: :ruby_method, identifier: identifier, file_path: '/app/example.rb')
  end

  it 'keeps real instance and singleton return types separate through JSON and analysis' do
    traces = described_class.record do
      TraceKindFixture::Parent.new.run
      TraceKindFixture::Parent.run
    end
    path = File.expand_path('../fixtures/trace_kind_fixture.rb', __dir__)
    units = Woods::RubyAnalyzer.analyze(paths: [path], trace_data: JSON.parse(JSON.generate(traces)))
    instance = units.find { |item| item.identifier == 'TraceKindFixture::Parent#run' }
    singleton = units.find { |item| item.identifier == 'TraceKindFixture::Parent.run' }

    expect(instance.metadata[:trace]).to include(call_count: 1, return_types: ['Integer'])
    expect(singleton.metadata[:trace]).to include(call_count: 1, return_types: ['String'])
  end

  it 'records inherited singleton methods under their defining owner and preserves caller kind' do
    traces = described_class.record { TraceKindFixture::Child.invoke }
    events = traces.select { |event| event[:method_name] == 'run' }
    expect(events).to all(include(class_name: 'TraceKindFixture::Parent', method_kind: 'singleton',
                                  caller_class: 'TraceKindFixture::Parent', caller_method: 'invoke',
                                  caller_method_kind: 'singleton'))
    units = [unit('TraceKindFixture::Parent.run'), unit('TraceKindFixture::Child.run')]
    described_class.merge(units: units, trace_data: traces)
    expect(units.first.metadata[:trace][:callers]).to include(
      'caller_class' => 'TraceKindFixture::Parent', 'caller_method' => 'invoke',
      'caller_method_kind' => 'singleton'
    )
    expect(units.last.metadata[:trace]).to be_nil
  end

  it 'distinguishes real same-name instance and singleton callers of one method' do
    traces = described_class.record do
      TraceKindFixture::Parent.new.invoke
      TraceKindFixture::Parent.invoke
    end
    callee = unit('TraceKindFixture::Parent.run')
    described_class.merge(units: [callee], trace_data: JSON.parse(JSON.generate(traces)))
    callers = callee.metadata[:trace][:callers]
    expect(callers).to eq([
                            { 'caller_class' => 'TraceKindFixture::Parent', 'caller_method' => 'invoke',
                              'caller_method_kind' => 'instance' },
                            { 'caller_class' => 'TraceKindFixture::Parent', 'caller_method' => 'invoke',
                              'caller_method_kind' => 'singleton' }
                          ])
  end

  it 'keeps all caller identity fields unknown when an unnamed frame calls a named method' do
    caller = Object.new
    def caller.invoke
      TraceKindFixture::Parent.run
    end
    traces = described_class.record { caller.invoke }
    events = traces.select { |event| event[:method_name] == 'run' }
    expect(events.size).to eq(2)
    expect(events).to all(include(caller_class: nil, caller_method: nil, caller_method_kind: nil))
  end

  it 'names module singleton owners' do
    traces = described_class.record { TraceKindFixture::Factory.run }
    expect(traces).to include(include(class_name: 'TraceKindFixture::Factory', method_kind: 'singleton',
                                      return_class: 'Symbol'))
  end

  it 'retains instance identity for methods supplied by an extended module' do
    extension = Module.new do
      def extended_run
        1.5
      end
    end
    stub_const('TraceKindExtension', extension)
    receiver = Class.new
    receiver.extend(extension)
    traces = described_class.record { receiver.extended_run }
    expect(traces).to include(include(class_name: 'TraceKindExtension', method_kind: 'instance',
                                      return_class: 'Float'))
  end

  it 'leaves anonymous singleton owners and individual object singleton owners unknown' do
    anonymous = Class.new do
      def self.run
        'anonymous'
      end
    end
    object = TraceKindFixture::Parent.new
    def object.run
      :individual
    end
    traces = described_class.record do
      anonymous.run
      object.run
    end
    events = traces.select { |event| event[:method_name] == 'run' }
    expect(events.size).to eq(4)
    expect(events).to all(include(class_name: nil, method_kind: 'singleton'))
    instance = unit('TraceKindFixture::Parent#run')
    described_class.merge(units: [instance], trace_data: traces)
    expect(instance.metadata[:trace]).to be_nil
  end

  it 'treats legacy named-owner traces as instance-only even when only a singleton unit is supplied' do
    traces = [{ class_name: 'Example', method_name: 'run', event: 'return', return_class: 'Integer' }]
    units = [unit('Example#run'), unit('Example.run')]
    described_class.merge(units: units, trace_data: traces)
    expect(units.first.metadata[:trace][:return_types]).to eq(['Integer'])
    expect(units.last.metadata[:trace]).to be_nil
    singleton = unit('Example.run')
    described_class.merge(units: [singleton], trace_data: traces)
    expect(singleton.metadata[:trace]).to be_nil
  end

  it 'skips unsupported explicit kinds and old singleton owner strings' do
    traces = [{ class_name: 'Example', method_name: 'run', method_kind: 'unknown', event: 'call' },
              { class_name: '#<Class:Example>', method_name: 'run', event: 'call' }]
    units = [unit('Example#run'), unit('Example.run')]
    described_class.merge(units: units, trace_data: traces)
    expect(units.map { |item| item.metadata[:trace] }).to all(be_nil)
  end

  it 'accepts symbol method and caller kinds' do
    traces = [{ class_name: 'Example', method_name: 'run', method_kind: :singleton, event: 'call',
                caller_class: 'Caller', caller_method: 'run', caller_method_kind: :instance }]
    singleton = unit('Example.run')
    described_class.merge(units: [singleton], trace_data: traces)
    expect(singleton.metadata[:trace][:callers]).to eq([
                                                         { 'caller_class' => 'Caller', 'caller_method' => 'run',
                                                           'caller_method_kind' => 'instance' }
                                                       ])
  end
end
