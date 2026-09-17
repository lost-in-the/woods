# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/middleware_argument'

RSpec.describe Woods::Extractors::MiddlewareArgument do
  it 'preserves nested values and literal identity-like strings' do
    value = { port: 3000, options: [true, nil, '#<Widget:0xabc123>'] }
    expect(described_class.render(value)).to eq('{:port=>3000, :options=>[true, nil, "#<Widget:0xabc123>"]}')
    expect(described_class.render(value.merge(port: 4000))).not_to eq(described_class.render(value))
  end

  it 'retains named classes and distinguishes anonymous parents and method origins' do
    expect(described_class.render(String)).to eq('String')
    expect(described_class.render(Class.new(String))).not_to eq(described_class.render(Class.new(Array)))
    first = Class.new { def call; end }
    second = Class.new { def call; end }
    expect(described_class.render(first)).not_to eq(described_class.render(second))
  end

  it 'renders temporary class names structurally while preserving literal name strings' do
    first = Class.new(String)
    second = Class.new(String)
    [first, second].each_with_index do |klass, index|
      temporary_name = "Executor(#<Application:0x#{index + 1}abc>)"
      if klass.respond_to?(:set_temporary_name)
        klass.set_temporary_name(temporary_name)
      else
        allow(klass).to receive(:name).and_return(temporary_name)
      end
      expect(described_class.render(temporary_name)).to eq(temporary_name)
    end
    expect(described_class.render(first)).to eq('#<anonymous Class < String>')
    expect(described_class.render(second)).to eq(described_class.render(first))
  end

  it 'preserves Ruby constant names containing Unicode characters' do
    klass = Class.new
    stub_const('MiddlewareÉclair', klass)
    expect(described_class.render(klass)).to eq('MiddlewareÉclair')
  end

  it 'describes opaque default objects by class without enumerating their instance variables' do
    object = Object.new
    object.instance_variable_set(:@secret, 'not-public')
    expect(described_class.render(object)).to eq('#<Object>')
    expect(described_class.render(Object.new)).to eq(described_class.render(object))
  end

  it 'preserves explicit application textual representations unchanged' do
    object = Object.new
    def object.to_s
      'configured #<Widget:0xabc123>'
    end
    expect(described_class.render(object)).to eq('configured #<Widget:0xabc123>')
  end

  it 'handles recursive containers without mistaking repeated values for cycles' do
    array = %w[same same]
    array << array
    expect(described_class.render(array)).to eq('["same", "same", <recursive Array>]')
  end

  it 'distinguishes procs by their source and lambda semantics without invoking them' do
    first = -> { raise 'must not run' }
    second = proc { raise 'must not run' }
    expect(described_class.render(first)).not_to eq(described_class.render(second))
    expect(described_class.render(first)).to include(__FILE__)
    expect(described_class.render(first)).not_to match(/0x[0-9a-f]+/)
  end
end
