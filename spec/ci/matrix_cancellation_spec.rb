# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'yaml'

RSpec.describe 'CI matrix cancellation' do
  let(:jobs) do
    YAML.safe_load_file(File.expand_path('../../.github/workflows/ci.yml', __dir__), aliases: true).fetch('jobs')
  end

  %w[test rails-matrix].each do |id|
    it "cancels siblings only on pull requests in #{id}" do
      expect(jobs.fetch(id).dig('strategy', 'fail-fast')).to eq("${{ github.event_name == 'pull_request' }}")
    end
  end

  { 'test-required' => ['ruby-version', '3.3'], 'rails-required' => ['rails', '7.2'] }.each do |id, (axis, value)|
    it "protects #{id} from failures in the other matrix rows" do
      job = jobs.fetch(id)
      matrix_id = id == 'test-required' ? 'test' : 'rails-matrix'
      expect(job).not_to have_key('needs')
      expect(job.dig('strategy', 'fail-fast')).to be(false)
      expect(job.dig('strategy', 'matrix', 'include')).to contain_exactly(a_hash_including(axis => value))
      expect(jobs.fetch(matrix_id).dig('strategy', 'matrix', 'include')).not_to include(a_hash_including(axis => value))
      expect(job.fetch('steps')).to eq(jobs.fetch(matrix_id).fetch('steps'))
      expect(job.fetch('name')).to eq(jobs.fetch(matrix_id).fetch('name'))
      expect(job.fetch('env')).to eq(jobs.fetch(matrix_id).fetch('env'))
      expect(job.fetch('runs-on')).to eq(jobs.fetch(matrix_id).fetch('runs-on'))
    end
  end

  it 'schedules each supported unit row exactly once' do
    rows = %w[test test-required].flat_map { |id| jobs.fetch(id).dig('strategy', 'matrix', 'include') }
    expect(rows.map { |row| row.fetch('ruby-version') }).to contain_exactly('3.0', '3.1', '3.2', '3.3', '3.4', '4.0')
  end

  it 'retains the required retrieval, coverage upload, and optional Rails fixture steps' do
    unit_steps = jobs.fetch('test-required').fetch('steps')
    expect(unit_steps).to include(a_hash_including('name' => 'Gate captured real-model retrieval quality'))
    expect(unit_steps).to include(a_hash_including('name' => 'Run tests with coverage'))
    expect(unit_steps).to include(a_hash_including('name' => 'Publish SimpleCov report',
                                                   'if' => "${{ env.WOODS_CI_ROW_ACTIVE == 'true' && " \
                                                           "(!cancelled() && matrix.ruby-version == '3.3') }}"))
    commands = jobs.fetch('rails-required').fetch('steps').filter_map { |step| step['run'] }.join("\n")
    expect(commands).to include('spec/integration/library_contributors_spec.rb',
                                'spec/integration/incremental_runtime_spec.rb',
                                'spec/integration/state_machine_forms_spec.rb',
                                'spec/integration/component_ownership_spec.rb')
  end

  it 'fails the coverage check unless both unit jobs succeed' do
    coverage = jobs.fetch('coverage')
    expect(coverage.fetch('needs')).to contain_exactly('test', 'test-required')
    expect(coverage.fetch('if')).to eq('${{ !cancelled() }}')
    step = coverage.fetch('steps').fetch(0)
    expect(step.fetch('env')).to eq('TEST_RESULT' => '${{ needs.test.result }}',
                                    'REQUIRED_RESULT' => '${{ needs.test-required.result }}')
    %w[success failure cancelled skipped].repeated_permutation(2) do |matrix_result, required_result|
      _, status = Open3.capture2e({ 'TEST_RESULT' => matrix_result, 'REQUIRED_RESULT' => required_result },
                                  'bash', '-c', step.fetch('run'))
      expect(status.success?).to eq(matrix_result == 'success' && required_result == 'success')
    end
  end
end
