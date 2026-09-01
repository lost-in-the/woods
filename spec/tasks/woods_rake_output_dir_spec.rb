# frozen_string_literal: true

require 'spec_helper'

# Extraction-family tasks (`extract`, `incremental`, `watch`, `refresh`,
# `extract_framework`, `validate`, `stats`, `clean`, `flow`) used to default
# `WOODS_OUTPUT` straight to `Rails.root.join('tmp/woods')`, while the embed
# family (`embed`, `embed_incremental`, `notion_sync`, `unblocked_sync`,
# `obsidian`) already fell back to `Woods.configuration.output_dir`. A host
# that set `config.output_dir` away from the default got a silent
# split-brain: extraction wrote the hardcoded path, embedding and every
# reader looked at the configured one.
#
# Same text-level approach as woods_rake_requires_spec: the task bodies
# require a booted Rails app to execute, so the regression is pinned by
# reading the source rather than invoking the tasks.
RSpec.describe 'lib/tasks/woods.rake output_dir resolution' do
  let(:source) { File.read(File.expand_path('../../lib/tasks/woods.rake', __dir__), encoding: 'UTF-8') }

  def task_body(name)
    lines = source.lines
    start = lines.index { |line| line.match?(/^  task[ :]+#{Regexp.escape(name)}\b/) }
    raise "could not locate the #{name} task in lib/tasks/woods.rake" if start.nil?

    rest = lines[(start + 1)..]
    stop = rest.index { |line| line.match?(/^  (desc|task)\b/) } || rest.length
    rest[0...stop].join
  end

  # `watch_status` is deliberately excluded: it is not an `:environment` task,
  # by design it derives the conventional path without booting Rails at all,
  # so it cannot read `Woods.configuration`.
  extraction_family = %w[extract incremental watch refresh extract_framework validate stats clean flow].freeze

  extraction_family.each do |name|
    it "woods:#{name} falls back to Woods.configuration.output_dir, not a hardcoded tmp/woods" do
      body = task_body(name)

      expect(body).to include("ENV.fetch('WOODS_OUTPUT', Woods.configuration.output_dir)")
      expect(body).not_to include("Rails.root.join('tmp/woods')")
    end
  end

  it 'watch_status keeps its own no-boot default (documented exception)' do
    body = task_body('watch_status')

    expect(body).to include("ENV.fetch('WOODS_OUTPUT') { File.join(woods_task_root, 'tmp/woods') }")
    expect(body).not_to include('Dir.pwd')
  end
end
