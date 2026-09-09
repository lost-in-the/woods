# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'woods/evaluation/ablation_runner'
require 'woods/evaluation/ablation_provenance'
require 'woods/evaluation/ablation_report_writer'

RSpec.describe Woods::Evaluation::AblationReportWriter do
  let(:provenance) do
    Woods::Evaluation::AblationProvenance.new(agent_command: 'agent --on', model: 'claude-x', config: '.mcp.json',
                                              woods_generation: 3, baseline_sha: 'abc123')
  end
  let(:result) do
    Woods::Evaluation::AblationRunner::Result.new(task_id: 'a', condition: :on, resolved: true, total_tokens: 150,
                                                  cost_usd: 0.02, turns: 4, duration_ms: 1000, error: nil,
                                                  provenance: provenance)
  end
  let(:report) do
    Woods::Evaluation::AblationRunner::Report.new(
      results: [result],
      summary: { on: { resolution_rate: 1.0, mean_tokens: 150.0, mean_cost_usd: 0.02, mean_turns: 4.0, tasks: 1,
                       errors: 0 } }
    )
  end

  describe '#write' do
    it 'writes the summary and results, with provenance expanded to a plain hash, as JSON' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'nested', 'eval_ablation.json')

        described_class.new(report).write(path)
        written = JSON.parse(File.read(path))

        expect(written['summary']).to eq('on' => { 'resolution_rate' => 1.0, 'mean_tokens' => 150.0,
                                                   'mean_cost_usd' => 0.02, 'mean_turns' => 4.0, 'tasks' => 1,
                                                   'errors' => 0 })
        expect(written['results'].first['task_id']).to eq('a')
        expect(written['results'].first['provenance']).to eq('agent_command' => 'agent --on', 'model' => 'claude-x',
                                                             'config' => '.mcp.json', 'woods_generation' => 3,
                                                             'baseline_sha' => 'abc123')
      end
    end
  end

  describe '#summary_text' do
    it 'renders the paired-run disclaimer and each condition present in the summary' do
      text = described_class.new(report).summary_text

      expect(text).to include('not causal evidence')
      expect(text).to include('on:')
      expect(text).to include('resolution_rate')
      expect(text).not_to include('off:')
      expect(text).not_to include('delta:')
    end
  end
end
