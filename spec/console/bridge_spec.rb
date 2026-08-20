# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/bridge'

RSpec.describe Woods::Console::StubBridge do
  it 'fails closed instead of returning static data' do
    expect do
      described_class.new(
        input: StringIO.new,
        output: StringIO.new,
        model_validator: Object.new,
        safe_context: Object.new
      )
    end.to raise_error(Woods::Console::UnsupportedBridgeError, /not supported/i)
  end
end
