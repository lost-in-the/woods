# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'
require 'woods'
require 'woods/explorer/flow_digest'

RSpec.describe Woods::Explorer::FlowDigest do
  around do |example|
    Dir.mktmpdir do |dir|
      @index_dir = dir
      @flows_dir = File.join(dir, 'flows')
      example.run
    end
  end

  # Mirrors FlowDocument#to_h after its JSON round-trip (string keys).
  let(:create_flow) do
    {
      'entry_point' => 'PostsController#create',
      'route' => { 'verb' => 'POST', 'path' => '/posts' },
      'max_depth' => 3,
      'generated_at' => '2026-07-01T00:00:00Z',
      'steps' => [
        {
          'unit' => 'PostsController#create',
          'type' => 'controller',
          'operations' => [
            { 'type' => 'call', 'target' => 'Post', 'method' => 'create!', 'line' => 12 },
            { 'type' => 'call', 'line' => 13, 'method' => 'process',
              'target' => '/gems/actionpack-8.0.1/lib/abstract_controller/base' },
            { 'type' => 'conditional', 'condition' => '@post.persisted?', 'line' => 14,
              'then_ops' => [
                { 'type' => 'async', 'target' => 'PublishPostJob', 'method' => 'perform_later', 'line' => 15 },
                { 'type' => 'async', 'target' => 'PostMailer', 'method' => 'published', 'line' => 16 }
              ],
              'else_ops' => [
                { 'type' => 'response', 'render_method' => 'render', 'status_code' => 422, 'line' => 18 }
              ] },
            { 'type' => 'response', 'render_method' => 'redirect', 'status_code' => 302, 'line' => 20 }
          ]
        },
        {
          'unit' => 'Post#create!',
          'type' => 'model',
          'operations' => [
            { 'type' => 'transaction', 'receiver' => 'Post', 'line' => 30,
              'nested' => [
                { 'type' => 'call', 'target' => 'AuditLog', 'method' => 'record', 'line' => 31 },
                { 'type' => 'conditional', 'condition' => 'audited?', 'line' => 32,
                  'then_ops' => [
                    { 'type' => 'call', 'target' => 'Metrics', 'method' => 'increment', 'line' => 33 }
                  ] }
              ] }
          ]
        }
      ]
    }
  end

  let(:show_flow) do
    {
      'entry_point' => 'UsersController#show',
      'route' => { 'verb' => 'GET', 'path' => '/users/:id' },
      'max_depth' => 3,
      'generated_at' => '2026-07-01T00:00:00Z',
      'steps' => [
        { 'unit' => 'UsersController#show', 'type' => 'controller',
          'operations' => [
            { 'type' => 'call', 'target' => 'User', 'method' => 'find', 'line' => 5 },
            { 'type' => 'call', 'target' => 'User', 'method' => 'update', 'line' => 6 },
            { 'type' => 'response', 'render_method' => 'render', 'status_code' => 200, 'line' => 7 }
          ] }
      ]
    }
  end

  def write_flow(filename, doc)
    FileUtils.mkdir_p(@flows_dir)
    File.write(File.join(@flows_dir, filename), JSON.pretty_generate(doc))
  end

  # Written in reverse-alphabetical order on purpose — the digest must read
  # files in sorted order regardless of creation order.
  def write_fixture_flows
    write_flow('UsersController_show.json', show_flow)
    write_flow('PostsController_create.json', create_flow)
    write_flow('flow_index.json', { 'PostsController#create' => '/abs/path.json' })
  end

  def digest
    described_class.new(@index_dir)
  end

  describe '#available?' do
    it 'is false when the flows directory is missing' do
      expect(digest.available?).to be(false)
    end

    it 'is false for an empty flows directory' do
      FileUtils.mkdir_p(@flows_dir)
      expect(digest.available?).to be(false)
    end

    it 'is false when only flow_index.json exists' do
      write_flow('flow_index.json', {})
      expect(digest.available?).to be(false)
    end

    it 'is true once flow documents exist' do
      write_fixture_flows
      expect(digest.available?).to be(true)
    end
  end

  describe '#build without flows' do
    it 'returns an empty digest with every key present' do
      expect(digest.build).to eq('summaries' => [], 'ops' => [],
                                 'unit_index' => {}, 'method_index' => {})
    end
  end

  describe '#build summaries' do
    before { write_fixture_flows }

    let(:summaries) { digest.build['summaries'] }
    let(:create_summary) { summaries[0] }
    let(:show_summary) { summaries[1] }

    it 'reads flows in sorted filename order regardless of write order' do
      expect(summaries.map { |s| s['entry'] })
        .to eq(['PostsController#create', 'UsersController#show'])
    end

    it 'captures the route as a [verb, path] pair' do
      expect(create_summary['route']).to eq(['POST', '/posts'])
    end

    it 'records the units each flow touches' do
      expect(create_summary['units']).to eq(['PostsController#create', 'Post#create!'])
    end

    it 'captures app calls as "Target#method" strings' do
      expect(create_summary['calls'])
        .to contain_exactly('Post#create!', 'AuditLog#record', 'Metrics#increment')
    end

    it 'splits async targets into jobs and mailers' do
      expect(create_summary['jobs']).to eq(['PublishPostJob'])
      expect(create_summary['mailers']).to eq(['PostMailer'])
    end

    it 'flags write calls (create!/update) by target' do
      expect(create_summary['writes']).to eq(['Post'])
      expect(show_summary['writes']).to eq(['User'])
    end

    it 'records responses as "render_method:status" strings' do
      expect(create_summary['responses']).to eq(['render:422', 'redirect:302'])
    end

    it 'counts conditionals including ones nested in transactions and branches' do
      expect(create_summary['conditions']).to eq(2)
      expect(show_summary['conditions']).to eq(0)
    end

    it 'strips gem-noise calls from the summary' do
      expect(create_summary['calls'].join).not_to include('/gems/')
    end
  end

  describe '#build compacted ops' do
    before { write_fixture_flows }

    let(:ops) { digest.build['ops'] }
    let(:controller_step) { ops[0][0] }
    let(:model_step) { ops[0][1] }

    it 'wraps each step with short u/t/ops keys' do
      expect(controller_step).to include('u' => 'PostsController#create', 't' => 'controller')
      expect(controller_step['ops']).to be_an(Array)
    end

    it 'compacts a call op to t/tgt/m/line' do
      expect(controller_step['ops'].first)
        .to eq('t' => 'call', 'tgt' => 'Post', 'm' => 'create!', 'line' => 12)
    end

    it 'strips gem-noise ops from the compacted tree' do
      targets = controller_step['ops'].map { |op| op['tgt'].to_s }
      expect(targets.join).not_to include('/gems/')
      expect(controller_step['ops'].size).to eq(3)
    end

    it 'compacts a conditional with cond/then/else branches' do
      conditional = controller_step['ops'][1]
      expect(conditional).to include('t' => 'conditional', 'cond' => '@post.persisted?', 'line' => 14)
      expect(conditional['then'])
        .to eq([{ 't' => 'async', 'tgt' => 'PublishPostJob', 'm' => 'perform_later', 'line' => 15 },
                { 't' => 'async', 'tgt' => 'PostMailer', 'm' => 'published', 'line' => 16 }])
      expect(conditional['else'])
        .to eq([{ 't' => 'response', 'status' => 422, 'render' => 'render', 'line' => 18 }])
    end

    it 'compacts a response with status/render keys' do
      expect(controller_step['ops'].last)
        .to eq('t' => 'response', 'status' => 302, 'render' => 'redirect', 'line' => 20)
    end

    it 'compacts transaction nesting under an ops key' do
      transaction = model_step['ops'].first
      expect(transaction).to include('t' => 'transaction', 'line' => 30)
      expect(transaction['ops'].first)
        .to eq('t' => 'call', 'tgt' => 'AuditLog', 'm' => 'record', 'line' => 31)
      expect(transaction['ops'][1]).to include('t' => 'conditional', 'cond' => 'audited?')
    end
  end

  describe '#build inverted indexes' do
    before { write_fixture_flows }

    let(:built) { digest.build }

    it 'maps each controller (entry unit before "#") to its flow indices' do
      expect(built['unit_index'])
        .to eq('Post' => [0], 'PostsController' => [0], 'UsersController' => [1])
    end

    it 'maps "Target#method" call strings to flow indices' do
      expect(built['method_index'])
        .to eq('AuditLog#record' => [0], 'Metrics#increment' => [0], 'Post#create!' => [0],
               'User#find' => [1], 'User#update' => [1])
    end
  end

  describe 'resilience and determinism' do
    before { write_fixture_flows }

    it 'skips a corrupt flow file without raising' do
      File.write(File.join(@flows_dir, '0_corrupt.json'), '{not json at all')
      built = nil
      expect { built = digest.build }.not_to raise_error
      expect(built['summaries'].size).to eq(2)
    end

    it 'is deterministic — two independent builds are equal' do
      expect(described_class.new(@index_dir).build).to eq(described_class.new(@index_dir).build)
    end
  end
end
