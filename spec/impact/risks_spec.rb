# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/impact/risks'
require 'woods/impact/value'

RSpec.describe Woods::Impact::Risks do
  let(:identity) { %w[ExampleJob job] }

  def inventory(retry_value)
    { identity => { 'metadata' => { 'job_type' => 'sidekiq', 'sidekiq_options' => { 'retry' => retry_value } } } }
  end

  def inspect_endpoint(payload, units, comparison, side, generation)
    reader = double('retained reader', payload_dir: Pathname.new(payload))
    described_class.new(reader, units, context: { 'endpoint' => side, 'generation' => generation }, limit: 100)
                   .call([identity], comparison: comparison)
  end

  [false, true].each do |base_retry|
    it "keeps retry policy local to each retained endpoint when base retry is #{base_retry}" do
      Dir.mktmpdir('impact-risk') do |payload|
        analysis = { 'hubs' => [], 'bridges' => [], 'cycles' => [], 'cross_database_edges' => [], 'stats' => {} }
        File.write(File.join(payload, 'graph_analysis.json'), JSON.generate(analysis))
        before = Woods::Impact::Value.copy(inventory(base_retry))
        after = Woods::Impact::Value.copy(inventory(!base_retry))
        original = [JSON.generate(before), JSON.generate(after)]
        base = inspect_endpoint(payload, before, after, 'from', 1)
        head = inspect_endpoint(payload, after, before, 'to', 2)
        flagged, unflagged, side, generation = base_retry ? [head, base, 'to', 2] : [base, head, 'from', 1]
        expect(flagged['risks']).to contain_exactly(
          'kind' => 'job_without_retry_touched', 'unit' => { 'identifier' => 'ExampleJob', 'type' => 'job' },
          'endpoint' => side, 'generation' => generation,
          'evidence' => { 'metadata_key' => 'retry_config/sidekiq_options', 'explicit_retry' => false }
        )
        expect(unflagged['risks']).to eq([])
        expect([JSON.generate(before), JSON.generate(after)]).to eq(original)
      end
    end
  end
end
