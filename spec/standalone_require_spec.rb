# frozen_string_literal: true

require 'spec_helper'
require 'open3'

# Files that name `Time#iso8601` or `FileUtils` without requiring them work
# in-process only because `require "woods"` pulls those in transitively — the
# suite can never see the gap. Proven in a subprocess, the way
# spec/tasks/woods_rake_generation_require_spec.rb proves its own.
#
# EXP-8 (evaluation/report_generator.rb) and EXTB-13 (flow_document.rb).
RSpec.describe 'standalone requires' do
  def load_and_run(script)
    root = File.expand_path('..', __dir__)
    Open3.capture3(RbConfig.ruby, '-I', File.join(root, 'lib'), '-e', script)
  end

  it 'builds an evaluation report after requiring report_generator alone' do
    script = <<~RUBY
      require 'tmpdir'
      require 'woods/evaluation/report_generator'
      report = Struct.new(:results, :aggregates, :threshold_report, keyword_init: true)
                     .new(results: [], aggregates: { total_queries: 0 }, threshold_report: nil)
      generator = Woods::Evaluation::ReportGenerator.new
      Dir.mktmpdir do |dir|
        generator.save(report, File.join(dir, 'report.json'))
      end
      print 'ok'
    RUBY

    out, err, status = load_and_run(script)

    expect(status.success?).to be(true), "expected success, got: #{err}"
    expect(out).to eq('ok')
  end

  it 'stamps a flow document after requiring flow_document alone' do
    script = <<~RUBY
      require 'woods/flow_document'
      print Woods::FlowDocument.new(entry_point: 'X').generated_at.empty? ? 'blank' : 'ok'
    RUBY

    out, err, status = load_and_run(script)

    expect(status.success?).to be(true), "expected success, got: #{err}"
    expect(out).to eq('ok')
  end
end
