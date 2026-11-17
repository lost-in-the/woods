# frozen_string_literal: true

require 'spec_helper'
require 'open3'

RSpec.describe StubbedEnv do
  # On Ruby 3.0 a plain Hash stub loses its class here and the next ENV call
  # segfaults; see spec/support/stubbed_env.rb.
  it 'leaves the stubbed ENV usable after a spawn that passes an environment hash' do
    replace_env(ENV.to_h.merge('WOODS_STUBBED_ENV_PROBE' => '1'))

    _out, _err, status = Open3.capture3({ 'GIT_OPTIONAL_LOCKS' => '0' }, 'true')

    expect(status).to be_success
    expect(ENV.fetch('WOODS_STUBBED_ENV_PROBE', nil)).to eq('1')
    expect(ENV.to_hash).not_to equal(ENV.to_hash)
  end

  it 'is the only way a spec replaces ENV' do
    root = File.expand_path('..', __dir__)
    helper = File.join(root, 'spec/support/stubbed_env.rb')
    pattern = /stub_const\(\s*['"](?:::)?ENV['"]/
    offenders = Dir.glob(File.join(root, 'spec/**/*.rb')).reject { |path| path == helper }.flat_map do |path|
      File.readlines(path, encoding: Encoding::UTF_8).each_with_index.filter_map do |line, index|
        "#{path.delete_prefix("#{root}/")}:#{index + 1}" if line.match?(pattern)
      end
    end

    expect(File.read(helper, encoding: Encoding::UTF_8)).to match(pattern)
    expect(offenders).to eq([]), 'use replace_env(values) instead of stub_const on ENV'
  end
end
