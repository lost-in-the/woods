# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'

RSpec.describe 'Real state machine declaration forms', :booted_app do
  it 'matches loaded registries through full, incremental and refresh extraction without running callbacks' do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', 'spec/fixtures/state_machine_forms/boot.rb')

    expect(status).to be_success, "#{stdout}\n#{stderr}"
    expect(JSON.parse(stdout.lines.last).fetch('checks')).to eq(
      ['default and named machines', 'runtime registry facts', 'AASM control',
       'full/incremental/refresh equivalence', 'no callback execution']
    )
  end
end
