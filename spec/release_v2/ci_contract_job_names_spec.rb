# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

# The release validator (script/validate-release-run) names the CI jobs a
# release candidate must have passed, by job id and name prefix. ci.yml is
# where those names live, so a rename there must move the validator too, or
# every release dispatch fails at release-context after the tag is pushed.
RSpec.describe 'release CI contract job names' do
  let(:ci_jobs) { YAML.load_file(File.expand_path('../../.github/workflows/ci.yml', __dir__)).fetch('jobs') }
  let(:required_jobs) do
    source = File.read(File.expand_path('../../script/validate-release-run', __dir__))
    literal = source[/REQUIRED_CI_JOBS = (\{.*?\})\.freeze/m, 1]
    eval(literal) # rubocop:disable Security/Eval
  end

  it 'names a ci.yml job for every required contract job' do
    expect(ci_jobs.keys).to include(*required_jobs.keys)
  end

  it 'uses a prefix that matches the static part of each required job name' do
    required_jobs.each do |job_id, prefix|
      job = ci_jobs.fetch(job_id)
      static_name = (job['name'] || job_id).split('${{').first
      expect(static_name).to start_with(prefix),
                             "#{job_id}: #{static_name.inspect} does not start with #{prefix.inspect}"
    end
  end
end
