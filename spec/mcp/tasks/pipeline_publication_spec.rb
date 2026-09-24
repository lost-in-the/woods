# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'
require 'woods/mcp/server'
require 'woods/mcp/index_reader'

RSpec.describe 'optional extraction pipeline publication reporting' do
  include_context 'published extraction failure fixture'

  let(:server) do
    Woods::MCP::Server.build(index_dir: output_dir, operator: {}, warmup: false, response_format: :json)
  end
  let(:tasks_meta) do
    {
      'io.modelcontextprotocol/protocolVersion' => MCP::Configuration::LATEST_MODERN_PROTOCOL_VERSION,
      'io.modelcontextprotocol/clientCapabilities' => { 'extensions' => { 'io.modelcontextprotocol/tasks' => {} } }
    }
  end
  let(:request_paths) { changed_paths }

  before { allow(Woods::Extractor).to receive(:new).with(output_dir: output_dir).and_return(extractor) }

  def rpc(method, params)
    JSON.parse(server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: method, params: params)))
  end

  def run_task(incremental)
    response = nil
    wait_for_threads do
      response = rpc('tools/call', 'name' => 'pipeline_extract', '_meta' => tasks_meta,
                                   'arguments' => { 'incremental' => incremental, 'changed_files' => request_paths })
    end
    expect(response.dig('result', 'resultType')).to eq('task')
    task_id = response.fetch('result').fetch('taskId')
    rpc('tasks/get', 'taskId' => task_id, '_meta' => tasks_meta).fetch('result')
  end

  context 'with restart-sensitive inputs in the embedded runtime' do
    let(:request_paths) { %w[db/schema.rb app/models/post.rb] }

    it 'fails the task with a fresh-boot remedy without changing the published generation' do
      task = run_task(true)
      expect(task.fetch('status')).to eq('failed')
      expect(task.dig('error', 'message')).to include('fresh Rails process', 'woods:extract')
      expect_previous_publication
      expect(File).not_to exist(File.join(output_dir, 'extraction.lock'))
    end
  end

  [false, true].each do |incremental|
    context "with incremental=#{incremental}" do
      it 'marks a genuinely published extraction completed' do
        expect(run_task(incremental).fetch('status')).to eq('completed')
        expect_complete_retry
      end

      %i[marker source_verification].each do |failure|
        it "marks #{failure} publication failure as failed and preserves the prior generation" do
          if failure == :marker
            allow_any_instance_of(Woods::Generation).to receive(:bump!).and_raise(IOError, 'marker write failed')
          else
            allow(extractor).to receive(:write_source_inputs).and_raise(Woods::ExtractionError,
                                                                        'source verification failed')
          end

          task = run_task(incremental)

          expect(task.fetch('status')).to eq('failed')
          expect(task.dig('error', 'message')).to include('Could not publish generation', 'previous generation')
          expect_previous_publication
          expect(File).not_to exist(File.join(output_dir, 'extraction.lock'))
        end
      end
    end
  end
end
