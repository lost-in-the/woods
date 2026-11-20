# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'
require 'tmpdir'

# A block queue (`queue_as { ... }`) is a different Proc object in every
# process, so each build below runs in its own Rails process. One process
# would reuse one Proc, and its builds would agree even if the published
# queue held that Proc's text.
RSpec.describe 'Job queue publication across independent Rails processes', :booted_app do
  before(:all) do
    @scratch = Dir.mktmpdir('woods_job_queue_determinism')
  end

  after(:all) do
    FileUtils.rm_rf(@scratch) if @scratch
  end

  # Every build uses the same application root, so the persisted files may
  # differ only in `extracted_at`, the time the unit was written.
  def build(mode)
    script = File.expand_path('../fixtures/job_queue_determinism/boot.rb', __dir__)
    env = { 'JOB_QUEUE_ROOT' => File.join(@scratch, 'app'), 'JOB_QUEUE_MODE' => mode }
    output, error, status = Open3.capture3(env, RbConfig.ruby, '-Ilib', script)
    expect(status.success?).to be(true), error
    JSON.parse(output.lines.last)
  end

  def persisted(result, identifier)
    result.dig('jobs', identifier, 'unit').except('extracted_at')
  end

  def expect_unresolved_queue(result)
    job = result.dig('jobs', 'ReportDigestJob')
    expect(job['raw']).not_to include('#<Proc')
    expect(job['raw']).not_to match(/:0x[0-9a-f]+/i)
    metadata = job.dig('unit', 'metadata')
    expect(metadata).to include('queue' => nil)
    expect(metadata.fetch('container')).to eq('kind' => 'jobs')
  end

  it 'publishes the same block-queue job from two independent full builds' do
    first = build('full')
    second = build('full')

    expect(persisted(second, 'ReportDigestJob')).to eq(persisted(first, 'ReportDigestJob'))
  end

  it 'leaves a block queue unresolved in the metadata and the container' do
    expect_unresolved_queue(build('full'))
  end

  it 'publishes the same block-queue job after an incremental edit as a clean full build of the edited tree' do
    incremental = build('incremental')
    full = build('full_edited')

    expect(persisted(incremental, 'ReportDigestJob').fetch('source_hash')).not_to eq(incremental.fetch('before_hash'))
    expect(persisted(incremental, 'ReportDigestJob')).to eq(persisted(full, 'ReportDigestJob'))
    expect_unresolved_queue(incremental)
  end

  it 'keeps a queue stated as a symbol or a string by name' do
    result = build('full')

    { 'ReportLowJob' => 'low', 'ReportCriticalJob' => 'critical' }.each do |identifier, queue|
      metadata = persisted(result, identifier).fetch('metadata')
      expect(metadata['queue']).to eq(queue)
      expect(metadata.fetch('container')).to eq('kind' => 'jobs', 'queue' => queue)
    end
  end
end
