# frozen_string_literal: true

require 'spec_helper'
require 'woods/deprecation'

RSpec.describe Woods::Deprecation do
  before { described_class.reset! }

  it 'warns on the first use of a key' do
    expect { described_class.warn_once(:thing, 'use the other thing') }
      .to output("[woods] DEPRECATED: use the other thing\n").to_stderr
  end

  it 'stays silent on later uses of the same key' do
    described_class.warn_once(:thing, 'use the other thing')
    expect { described_class.warn_once(:thing, 'use the other thing') }.not_to output.to_stderr
  end

  it 'warns separately for a different key' do
    described_class.warn_once(:thing, 'one')
    expect { described_class.warn_once(:other, 'two') }.to output(/two/).to_stderr
  end
end
