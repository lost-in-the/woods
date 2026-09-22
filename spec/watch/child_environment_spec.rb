# frozen_string_literal: true

require 'spec_helper'
require 'woods/watch/child_environment'

RSpec.describe Woods::Watch::ChildEnvironment do
  it 'removes Bundler-injected activation while preserving the selected Gemfile and application settings' do
    env = { 'BUNDLE_GEMFILE' => 'Gemfile', 'BUNDLE_LOCKFILE' => '/old/project/Gemfile.lock',
            'BUNDLE_BIN_PATH' => '/old/bundler/bin', 'RUBYOPT' => '-r/old/bundler/setup',
            'BUNDLER_ORIG_RUBYOPT' => '-rjson',
            'BUNDLER_ORIG_BUNDLE_LOCKFILE' => described_class::NIL_VALUE,
            'RAILS_ENV' => 'development', 'APP_SETTING' => 'keep' }
    result = described_class.build(env, root: '/app with spaces')

    expect(result).to include('BUNDLE_GEMFILE' => '/app with spaces/Gemfile', 'RUBYOPT' => '-rjson',
                              'RAILS_ENV' => 'development', 'APP_SETTING' => 'keep')
    expect(result.keys.grep(/BUNDLER_ORIG_|BUNDLE_LOCKFILE|BUNDLE_BIN_PATH/)).to be_empty
    expect(env['BUNDLE_LOCKFILE']).to eq('/old/project/Gemfile.lock')
  end

  it 'retains a genuinely user-selected alternate lockfile' do
    env = { 'BUNDLE_LOCKFILE' => '/activated.lock', 'BUNDLER_ORIG_BUNDLE_LOCKFILE' => '/requested.lock' }
    expect(described_class.build(env, root: '/app')['BUNDLE_LOCKFILE']).to eq('/requested.lock')
  end
end
