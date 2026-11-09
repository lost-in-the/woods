# frozen_string_literal: true

# Verification driver only. Reuses #1040's synthetic app/views concern shape
# and the candidate's canonical IndexComparison; contains no production fix.
ENV['RAILS_ENV'] = 'test'
require 'logger'
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'json'
require 'fileutils'
require 'open3'
require 'woods'
require 'woods/extractor'
require 'woods/mcp/index_reader'
require File.join(Dir.pwd, 'spec/support/index_comparison')

root, mode, output, fault = ARGV
helper_source = "module CardsHelper\n  def label; 'before'; end\nend\n"
if mode == 'resident'
  files = {
    'config/routes.rb' => 'Rails.application.routes.draw { get "/cards", to: "cards#index" }',
    'config/database.yml' => JSON.generate('test' => { adapter: 'sqlite3', database: ':memory:' }),
    'app/controllers/cards_controller.rb' => "class CardsController < ActionController::Base\n " \
                                             "def index; head :ok; end\nend",
    'app/helpers/cards_helper.rb' => helper_source,
    'app/views/ui/decorated.rb' => "module Ui::Decorated\n extend ActiveSupport::Concern\n " \
                                   "def decorated; :present; end\nend\n",
    'app/views/ui/labelled.rb' => "module Ui::Labelled\n extend ActiveSupport::Concern\n include Ui::Decorated\nend\n"
  }
  files.each do |path, content|
    target = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, content)
  end
end
app = Class.new(Rails::Application)
Object.const_set(:VerificationResidentApplication, app)
app.config.root = root
app.config.eager_load = false
app.config.cache_classes = false
app.config.secret_key_base = 'synthetic-verification-only'
app.config.logger = Logger.new(IO::NULL)
app.config.autoload_paths << File.join(root, 'app/views')
app.initialize!
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
Woods.configure do |config|
  config.concurrent_extraction = false
  config.enable_snapshots = false
  config.include_framework_sources = false
end

if mode == 'cold'
  Woods::Extractor.new(output_dir: output).tap do |extractor|
    extractor.extract_all
    extractor.raise_on_publication_failure!
  end
  puts JSON.generate(status: 'cold_complete', pid: Process.pid)
  exit
end

class VerificationAssertion < StandardError; end

def assert_verification(report, name)
  result = yield
  report[:checks] << { name: name, passed: result != false && !result.nil? }
  raise VerificationAssertion, name unless result
end

def cold_oracle(root, output, report)
  command = [RbConfig.ruby, '-Ilib', File.expand_path(__FILE__), root, 'cold', output]
  stdout, stderr, status = Open3.capture3(*command)
  report[:oracles] << { output: output, stdout: stdout, stderr: stderr, exit_status: status.exitstatus }
  raise "cold process failed: #{stderr}" unless status.success?

  result = JSON.parse(stdout.lines.last)
  return if result['status'] == 'cold_complete' && result['pid'] != Process.pid

  raise 'cold oracle did not complete independently'
end

report = { status: 'incomplete', checks: [], oracles: [], phases: [], resident_pid: Process.pid,
           fault: fault, comparison: 'candidate spec/support/index_comparison.rb' }
begin
  Woods::Extractor.new(output_dir: output).extract_all
  before_generation = Woods::Generation.new(output_dir: output).current.number
  cold_a = File.join(root, 'tmp/cold-a')
  cold_b = File.join(root, 'tmp/cold-b')
  cold_oracle(root, cold_a, report)
  cold_oracle(root, cold_b, report)
  baseline_differences = IndexComparison.differences(cold_a, cold_b)
  report[:full_full_differences] = baseline_differences
  assert_verification(report, 'independent full/full baseline agrees') { baseline_differences.empty? }
  assert_verification(report, 'resident baseline agrees with independent cold full') do
    IndexComparison.differences(output, cold_a).empty?
  end
  reader = Woods::MCP::IndexReader.new(output)
  present = -> { %w[Ui::Decorated Ui::Labelled].all? { |name| reader.find_unit(name, type: 'concern') } }
  assert_verification(report, 'baseline contains both concerns') { present.call }

  helper = File.join(root, 'app/helpers/cards_helper.rb')
  %w[edit restore].each_with_index do |phase, index|
    File.write(helper, phase == 'edit' ? helper_source.sub("'before'", "'after'") : helper_source)
    Rails.application.reloader.reload!
    assert_verification(report, "#{phase} unloads views namespace") { Object.autoload?(:Ui) }
    Woods::Extractor.new(output_dir: output).extract_changed([helper]) unless fault == 'skip_incremental'
    cold = File.join(root, "tmp/cold-#{phase}")
    cold_oracle(root, cold, report)
    differences = IndexComparison.differences(output, cold)
    generation = Woods::Generation.new(output_dir: output).current.number
    report[:phases] << { phase: phase, generation: generation, concerns_present: present.call,
                         differences: differences }
    assert_verification(report, "#{phase} advances publication") { generation == before_generation + index + 1 }
    assert_verification(report, "#{phase} retains both concerns") { present.call }
    assert_verification(report, "#{phase} matches independent cold full") { differences.empty? }
  end
  report[:status] = 'passed'
rescue VerificationAssertion => e
  report[:status] = 'failed_assertion'
  report[:error] = e.message
rescue StandardError => e
  report[:status] = 'failed_harness'
  report[:error] = "#{e.class}: #{e.message}"
ensure
  puts JSON.generate(report)
end
