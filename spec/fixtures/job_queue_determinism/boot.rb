# frozen_string_literal: true

# One independent build of a small application whose jobs state their queue
# three ways: a block, a symbol and a string. The leaves carry no job marker
# (`def perform`, `< ApplicationJob`), so the extractor reaches them by class
# discovery, the path that reads `queue_name` from the loaded class.
#
# JOB_QUEUE_ROOT: the application root, recreated empty on every run.
# JOB_QUEUE_MODE: `full` (original tree), `full_edited` (the edited tree), or
#   `incremental` (full build of the original tree, edit, then extract_changed).
#
# Prints one JSON line: the persisted job files of the three leaves.
require 'logger'
require 'rails'
require 'active_record/railtie'
require 'active_job/railtie'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extractor'

BLOCK_JOB = 'app/jobs/report_digest_job.rb'
LEAVES = %w[ReportDigestJob ReportLowJob ReportCriticalJob].freeze

def block_job_source(queue)
  "class ReportDigestJob < ReportJob\n  queue_as { arguments.empty? ? '#{queue}' : 'bulk' }\nend\n"
end

ORIGINAL = block_job_source('digests')
EDITED = block_job_source('summaries')

def persisted_jobs(index)
  payload = Woods::Generation.new(output_dir: index).payload_dir
  Dir[File.join(payload, 'jobs', '*.json')].each_with_object({}) do |path, found|
    next if File.basename(path) == '_index.json'

    raw = File.read(path, encoding: 'UTF-8')
    unit = JSON.parse(raw)
    found[unit['identifier']] = { 'raw' => raw, 'unit' => unit } if LEAVES.include?(unit['identifier'])
  end
end

def full_build(index)
  Woods::Extractor.new(output_dir: index).extract_all
  persisted_jobs(index)
end

root = ENV.fetch('JOB_QUEUE_ROOT')
mode = ENV.fetch('JOB_QUEUE_MODE')
FileUtils.rm_rf(root)
FileUtils.mkdir_p(File.join(root, 'app/jobs'))
FileUtils.mkdir_p(File.join(root, 'config'))
File.write(File.join(root, 'config/database.yml'),
           JSON.generate(Rails.env => { adapter: 'sqlite3', database: ':memory:' }))
{
  'app/jobs/application_job.rb' => "class ApplicationJob < ActiveJob::Base\nend\n",
  'app/jobs/report_job.rb' => "class ReportJob < ApplicationJob\n  def perform(*) = nil\nend\n",
  'app/jobs/report_low_job.rb' => "class ReportLowJob < ReportJob\n  queue_as :low\nend\n",
  'app/jobs/report_critical_job.rb' => "class ReportCriticalJob < ReportJob\n  queue_as 'critical'\nend\n",
  BLOCK_JOB => mode == 'full_edited' ? EDITED : ORIGINAL
}.each { |relative, source| File.write(File.join(root, relative), source) }

app = Class.new(Rails::Application)
Object.const_set(:JobQueueDeterminismApplication, app)
app.config.root = root
app.config.eager_load = false
app.config.secret_key_base = 'job-queue-determinism-test'
app.config.logger = Logger.new(IO::NULL)
app.initialize!
app.eager_load!
raise 'the block queue is not a Proc at runtime' unless ReportDigestJob.queue_name.is_a?(Proc)

Woods.configuration.concurrent_extraction = false
index = File.join(root, 'tmp/woods')
jobs = full_build(index)
if mode == 'incremental'
  before_hash = jobs.fetch('ReportDigestJob').fetch('unit').fetch('source_hash')
  File.write(File.join(root, BLOCK_JOB), EDITED)
  load File.join(root, BLOCK_JOB)
  Woods::Extractor.new(output_dir: index).extract_changed([BLOCK_JOB])
  jobs = persisted_jobs(index)
end
raise "missing job units: #{(LEAVES - jobs.keys).inspect}" unless (LEAVES - jobs.keys).empty?

puts JSON.generate(jobs: jobs, before_hash: before_hash, queue_name: ReportDigestJob.queue_name.inspect)
