# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'mcp'
require 'timeout'
require 'woods'
require 'woods/dependency_graph'
require 'woods/coordination/pipeline_lock'
require 'woods/feedback/store'
require 'woods/feedback/gap_detector'
require 'woods/mcp/server'
require 'woods/notion/exporter'
require 'woods/operator/error_escalator'
require 'woods/operator/pipeline_guard'
require 'woods/operator/status_reporter'
require 'woods/session_tracer/session_flow_assembler'

RSpec.describe 'Index MCP tool contracts' do
  # Exact response literals are intentionally kept beside each tool contract.
  # rubocop:disable-next Layout/LineLength
  let(:contract_oracle) do
    {
      'codebase_retrieve' => contract(:always, { 'query' => 'How does Post work?' },
                                      exact_text("## Post\nclass Post; end"),
                                      required: %w[query], properties: {
                                        'query' => string_contract(1, 10_000),
                                        'budget' => integer_contract(1, 200_000),
                                        'types' => array_contract(1_000, 10_000),
                                        'exclude_types' => array_contract(1_000, 10_000)
                                      }),
      'dependencies' => contract(:always, { 'identifier' => 'Comment' }, exact_data({
                                                                                      'root' => 'Comment', 'found' => true,
                                                                                      'nodes' => {
                                                                                        'Comment' => {
                                                                                          'type' => 'model', 'depth' => 0, 'deps' => ['Post']
                                                                                        },
                                                                                        'Post' => { 'type' => 'model',
                                                                                                    'depth' => 1, 'deps' => [] }
                                                                                      }
                                                                                    }),
                                 required: %w[identifier], properties: {
                                   'identifier' => string_contract(1, 10_000),
                                   'depth' => integer_contract(0, 20),
                                   'types' => array_contract(1_000, 10_000),
                                   'via' => union_contract
                                 }),
      'dependents' => contract(:always, { 'identifier' => 'Post' }, exact_data({
                                                                                 'root' => 'Post', 'found' => true,
                                                                                 'nodes' => {
                                                                                   'Post' => { 'type' => 'model', 'depth' => 0,
                                                                                               'deps' => %w[Comment PostsController] },
                                                                                   'Comment' => { 'type' => 'model',
                                                                                                  'depth' => 1, 'deps' => [] },
                                                                                   'PostsController' => {
                                                                                     'type' => 'controller', 'depth' => 1, 'deps' => []
                                                                                   }
                                                                                 }
                                                                               }),
                               required: %w[identifier], properties: {
                                 'identifier' => string_contract(1, 10_000),
                                 'depth' => integer_contract(0, 20),
                                 'types' => array_contract(1_000, 10_000),
                                 'via' => union_contract
                               }),
      'domain_clusters' => contract(:always, {}, exact_data({
                                                              'clusters' => [{ 'name' => 'Billing', 'member_count' => 2,
                                                                               'hub' => 'PaymentService' }],
                                                              'total' => 1
                                                            }), properties: {
                                                              'min_size' => integer_contract(1, 100_000),
                                                              'types' => array_contract(1_000, 10_000)
                                                            }),
      'framework' => contract(:always, { 'keyword' => 'ActiveRecord' }, exact_data({
                                                                                     'keyword' => 'ActiveRecord', 'result_count' => 1,
                                                                                     'results' => [{
                                                                                       'identifier' => 'ActiveRecord::Base', 'type' => 'rails_source',
                                                                                       'file_path' => 'activerecord-8.1.2/lib/active_record/base.rb',
                                                                                       'metadata' => { 'gem_name' => 'activerecord', 'gem_version' => '8.1.2',
                                                                                                       'concept' => 'persistence' }
                                                                                     }]
                                                                                   }),
                              required: %w[keyword], properties: {
                                'keyword' => string_contract(1, 10_000),
                                'limit' => integer_contract(1, 1_000)
                              }),
      'graph_analysis' => contract(:always, { 'analysis' => 'orphans' }, exact_data({
                                                                                      'orphans' => ['PostsController'],
                                                                                      'stats' => {
                                                                                        'orphan_count' => 1, 'dead_end_count' => 1,
                                                                                        'hub_count' => 3, 'cycle_count' => 0
                                                                                      }
                                                                                    }),
                                   properties: {
                                     'analysis' => enum_contract(
                                       %w[orphans dead_ends hubs cycles bridges all], nil, 10_000
                                     ),
                                     'limit' => integer_contract(1, 1_000),
                                     'offset' => integer_contract(0, 1_000_000)
                                   }),
      'list_snapshots' => contract(:snapshot, {}, exact_data({
                                                               'snapshot_count' => 1,
                                                               'snapshots' => [{ 'git_sha' => 'aaa111',
                                                                                 'branch' => 'main' }]
                                                             }), properties: {
                                                               'limit' => integer_contract(1, 1_000),
                                                               'branch' => string_contract(nil, 10_000)
                                                             }),
      'lookup' => contract(:always, { 'identifier' => 'Post' }, data_projection(
                                                                  [%w[type], 'model'],
                                                                  [%w[identifier], 'Post'],
                                                                  [%w[file_path], 'app/models/post.rb'],
                                                                  [%w[source_code], "class Post < ApplicationRecord\n  has_many :comments\n  " \
                                                                                    "validates :title, presence: true\nend\n"],
                                                                  [%w[metadata associations], [{ 'type' => 'has_many', 'name' => 'comments',
                                                                                                 'class_name' => 'Comment' }]],
                                                                  [%w[dependencies], []],
                                                                  [%w[dependents], %w[Comment PostsController]],
                                                                  key_sets: {
                                                                    [] => %w[type identifier file_path namespace source_code metadata dependencies
                                                                             dependents chunks extracted_at source_hash]
                                                                  }
                                                                ),
                           properties: {
                             'identifier' => string_contract(nil, 10_000),
                             'name' => string_contract(nil, 10_000),
                             'include_source' => boolean_contract,
                             'sections' => array_contract(1_000, 10_000)
                           }),
      'notion_sync' => contract(:notion, {}, exact_data({
                                                          'synced' => true, 'data_models' => 2, 'columns' => 4, 'errors' => []
                                                        })),
      'pagerank' => contract(:always, {}, exact_data({
                                                       'total_nodes' => 3,
                                                       'results' => [
                                                         { 'identifier' => 'Post', 'type' => 'model',
                                                           'score' => 0.574465 },
                                                         { 'identifier' => 'Comment', 'type' => 'model',
                                                           'score' => 0.212767 },
                                                         { 'identifier' => 'PostsController', 'type' => 'controller',
                                                           'score' => 0.212767 }
                                                       ]
                                                     }), properties: {
                                                       'limit' => integer_contract(1, 1_000),
                                                       'types' => array_contract(1_000, 10_000)
                                                     }),
      'pipeline_diagnose' => contract(
        :operator, { 'error_class' => 'Timeout::Error', 'error_message' => 'timed out' },
        exact_data({
                     'severity' => 'transient', 'category' => 'timeout',
                     'remediation' => 'Retry after a short delay', 'error_class' => 'Timeout::Error',
                     'message' => 'timed out', 'original_class' => 'Timeout::Error'
                   }), required: %w[error_class error_message], properties: {
                     'error_class' => string_contract(1, 10_000),
                     'error_message' => string_contract(1, 10_000)
                   }
      ),
      'pipeline_embed' => contract(:operator, {}, exact_data({
                                                               'status' => 'started',
                                                               'message' => 'Embedding pipeline started in background thread'
                                                             }), properties: {
                                                               'incremental' => boolean_contract
                                                             }, effect: :embedding_cooldown),
      'pipeline_extract' => contract(:operator, {}, exact_data({
                                                                 'status' => 'started',
                                                                 'message' => 'Extraction pipeline started in background thread'
                                                               }), properties: {
                                                                 'incremental' => boolean_contract,
                                                                 'changed_files' => array_contract(1_000, 10_000)
                                                               }, effect: :extraction_cooldown),
      'pipeline_repair' => contract(:operator, { 'action' => 'reset_cooldowns' }, exact_data({
                                                                                               'repaired' => true, 'action' => 'reset_cooldowns', 'outcome' => 'reset'
                                                                                             }),
                                    required: %w[action], properties: {
                                      'action' => enum_contract(%w[clear_locks reset_cooldowns], 1, 10_000)
                                    }, effect: :cooldowns_reset),
      'pipeline_status' => contract(:operator, {}, data_projection(
                                                     [%w[status], 'stale'],
                                                     [%w[extracted_at], '2026-01-15T12:00:00Z'],
                                                     [%w[total_units], 9],
                                                     [%w[counts], expected_counts],
                                                     [%w[git_sha], 'abc1234'],
                                                     [%w[git_branch], 'main'],
                                                     key_sets: {
                                                       [] => %w[status extracted_at total_units counts git_sha git_branch
                                                                staleness_seconds]
                                                     },
                                                     types: { %w[staleness_seconds] => Numeric }
                                                   )),
      'recent_changes' => contract(:always, {}, exact_data({
                                                             'result_count' => 3,
                                                             'results' => [
                                                               { 'identifier' => 'Comment', 'type' => 'model',
                                                                 'file_path' => 'app/models/comment.rb',
                                                                 'last_modified' => '2026-01-14T16:00:00Z',
                                                                 'author' => 'dev@example.com' },
                                                               { 'identifier' => 'PostsController', 'type' => 'controller',
                                                                 'file_path' => 'app/controllers/posts_controller.rb',
                                                                 'last_modified' => '2026-01-12T10:00:00Z',
                                                                 'author' => 'dev@example.com' },
                                                               { 'identifier' => 'Post', 'type' => 'model',
                                                                 'file_path' => 'app/models/post.rb',
                                                                 'last_modified' => '2026-01-10T08:30:00Z',
                                                                 'author' => 'dev@example.com' }
                                                             ]
                                                           }), properties: {
                                                             'limit' => integer_contract(1, 1_000),
                                                             'types' => array_contract(1_000, 10_000)
                                                           }),
      'reload' => contract(:always, {}, exact_data({
                                                     'reloaded' => true, 'extracted_at' => '2026-01-15T12:00:00Z',
                                                     'total_units' => 10, 'counts' => expected_counts.merge('models' => 3)
                                                   }), effect: :reloaded_manifest),
      'retrieval_explain' => contract(:feedback, {}, exact_data({
                                                                  'total_ratings' => 1, 'average_score' => 2.0, 'total_gaps' => 0,
                                                                  'recent_ratings' => [{
                                                                    'type' => 'rating', 'query' => 'seed', 'score' => 2, 'comment' => nil,
                                                                    'timestamp' => '2026-01-01T00:00:00Z'
                                                                  }],
                                                                  'recent_gaps' => []
                                                                })),
      'retrieval_rate' => contract(:feedback, { 'query' => 'Post', 'score' => 4 }, exact_data({
                                                                                                'recorded' => true, 'type' => 'rating', 'query' => 'Post', 'score' => 4
                                                                                              }),
                                   required: %w[query score], properties: {
                                     'query' => string_contract(1, 10_000),
                                     'score' => integer_contract(1, 5),
                                     'comment' => string_contract(nil, 10_000)
                                   }, effect: :rating_persisted),
      'retrieval_report_gap' => contract(:feedback,
                                         { 'query' => 'Post', 'missing_unit' => 'Post', 'unit_type' => 'model' },
                                         exact_data({
                                                      'recorded' => true, 'type' => 'gap',
                                                      'missing_unit' => 'Post'
                                                    }), required: %w[query missing_unit unit_type], properties: {
                                                      'query' => string_contract(1, 10_000),
                                                      'missing_unit' => string_contract(1, 10_000),
                                                      'unit_type' => string_contract(1, 10_000)
                                                    }, effect: :gap_persisted),
      'retrieval_suggest' => contract(:feedback, {}, exact_data({
                                                                  'issues_found' => 1,
                                                                  'issues' => [{ 'kind' => 'missing_unit',
                                                                                 'count' => 1 }]
                                                                })),
      'search' => contract(
        :always, { 'query' => 'Post' }, exact_data({
                                                     'query' => 'Post', 'result_count' => 3,
                                                     'results' => [
                                                       { 'identifier' => 'Post', 'type' => 'model',
                                                         'match_field' => 'identifier' },
                                                       { 'identifier' => 'PostsController', 'type' => 'controller',
                                                         'match_field' => 'identifier' },
                                                       { 'identifier' => 'PostDecorator', 'type' => 'decorator',
                                                         'match_field' => 'identifier' }
                                                     ]
                                                   }),
        properties: {
          'query' => string_contract(nil, 10_000),
          'types' => array_contract(1_000, 10_000),
          'fields' => enum_array_contract(%w[identifier metadata source_code], 1_000, 10_000),
          'limit' => integer_contract(1, 1_000),
          'exact_prefix' => string_contract(nil, 10_000),
          'exact_suffix' => string_contract(nil, 10_000)
        }
      ),
      'session_trace' => contract(:session, { 'session_id' => 'session-1' },
                                  exact_text("## Session session-1\n1 request"),
                                  required: %w[session_id], properties: {
                                    'session_id' => string_contract(1, 10_000),
                                    'budget' => integer_contract(1, 200_000),
                                    'depth' => integer_contract(0, 20)
                                  }),
      'snapshot_detail' => contract(:snapshot, { 'git_sha' => 'aaa111' },
                                    exact_data({ 'git_sha' => 'aaa111', 'branch' => 'main' }),
                                    required: %w[git_sha], properties: {
                                      'git_sha' => string_contract(1, 10_000)
                                    }),
      'snapshot_diff' => contract(:snapshot, { 'sha_a' => 'aaa111', 'sha_b' => 'bbb222' }, exact_data({
                                                                                                        'sha_a' => 'aaa111', 'sha_b' => 'bbb222',
                                                                                                        'added' => 1, 'modified' => 0, 'deleted' => 0,
                                                                                                        'details' => { 'added' => ['Post'], 'modified' => [], 'deleted' => [] }
                                                                                                      }),
                                  required: %w[sha_a sha_b], properties: {
                                    'sha_a' => string_contract(1, 10_000),
                                    'sha_b' => string_contract(1, 10_000)
                                  }),
      'structure' => contract(:always, {}, exact_data({
                                                        'manifest' => expected_manifest,
                                                        'template_engines' => ['erb']
                                                      }), properties: {
                                                        'detail' => enum_contract(%w[summary full], nil, 10_000)
                                                      }),
      'trace_flow' => contract(:always, { 'entry_point' => 'PostsController#create' },
                               data_projection(
                                 [%w[entry_point], 'PostsController#create'],
                                 [%w[route], nil],
                                 [%w[max_depth], 3],
                                 # The fixture defines index/show but no create, so expansion
                                 # takes the documented named-but-undefined fallback: whole-unit
                                 # operations (not the old silently-empty list), and depth >= 1
                                 # follows the Post targets into the model step.
                                 [%w[steps], trace_flow_steps.fetch(:deep)],
                                 key_sets: { [] => %w[entry_point route max_depth generated_at steps] },
                                 types: { %w[generated_at] => String }
                               ),
                               required: %w[entry_point], properties: {
                                 'entry_point' => string_contract(1, 10_000),
                                 'depth' => integer_contract(0, 20)
                               }),
      'unit_history' => contract(:snapshot, { 'identifier' => 'Post' }, exact_data({
                                                                                     'identifier' => 'Post', 'versions' => 1,
                                                                                     'history' => [{ 'git_sha' => 'aaa111', 'identifier' => 'Post' }]
                                                                                   }),
                                 required: %w[identifier], properties: {
                                   'identifier' => string_contract(1, 10_000),
                                   'limit' => integer_contract(1, 1_000)
                                 }),
      'woods_status' => contract(:always, {}, data_projection(
                                                [%w[ready], true],
                                                [%w[server name], 'woods'],
                                                [%w[server version], Woods::VERSION],
                                                [%w[index extracted_at], '2026-01-15T12:00:00Z'],
                                                [%w[index total_units], 9],
                                                [%w[index counts], expected_counts],
                                                [%w[index git_sha], 'abc1234'],
                                                [%w[index git_branch], 'main'],
                                                [%w[watch state], 'absent'],
                                                [%w[retriever configured], true],
                                                [%w[features notion_configured], true],
                                                key_sets: {
                                                  [] => %w[ready server index watch retriever bootstrap features]
                                                }
                                              ))
    }
  end

  let(:source_fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:runtime_root) { Dir.mktmpdir('woods-tool-contract') }
  let(:fixture_dir) { File.join(runtime_root, 'woods') }
  let(:inventory_path) { File.expand_path('../../.Codex/release-v2/surface-inventory.json', __dir__) }
  let(:tool_contract_meta) do
    {
      'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
      'io.modelcontextprotocol/clientInfo' => { 'name' => 'tool-contract-spec', 'version' => '1.0' },
      'io.modelcontextprotocol/clientCapabilities' => {}
    }
  end
  let(:config) do
    Woods::Configuration.new.tap do |value|
      value.session_store = Class.new do
        def read(*) = nil
        def sessions = []
      end.new
      value.notion_api_token = 'test-token'
      value.notion_database_ids = { data_models: 'test-database' }
    end
  end
  let(:retriever) do
    double('retriever', retrieve: Struct.new(:context).new("## Post\nclass Post; end"))
  end
  let(:pipeline_guard) do
    Woods::Operator::PipelineGuard.new(state_dir: File.join(runtime_root, 'operator'), cooldown: 300)
  end
  let(:pipeline_lock) do
    Woods::Coordination::PipelineLock.new(
      lock_dir: File.join(runtime_root, 'operator'), name: 'extraction', stale_timeout: 60
    )
  end
  let(:operator) do
    {
      status_reporter: Woods::Operator::StatusReporter.new(output_dir: fixture_dir),
      error_escalator: Woods::Operator::ErrorEscalator.new,
      pipeline_guard: pipeline_guard,
      pipeline_lock: pipeline_lock
    }
  end
  let(:feedback_path) { File.join(runtime_root, 'feedback.jsonl') }
  let(:feedback_store) { Woods::Feedback::Store.new(path: feedback_path) }
  let(:snapshot_store) do
    double(
      'snapshot store',
      list: [{ git_sha: 'aaa111', branch: 'main' }],
      diff: { added: ['Post'], modified: [], deleted: [] },
      unit_history: [{ git_sha: 'aaa111', identifier: 'Post' }],
      find: { git_sha: 'aaa111', branch: 'main' }
    )
  end
  let(:notion_exporter) { double(sync_all: { data_models: 2, columns: 4, errors: [] }) }
  let(:full_server) { build_full_server }

  before do
    FileUtils.cp_r(source_fixture_dir, fixture_dir)
    seed_rating = JSON.generate(
      type: 'rating', query: 'seed', score: 2, comment: nil,
      timestamp: '2026-01-01T00:00:00Z'
    )
    File.write(feedback_path, "#{seed_rating}\n")
    allow(Woods).to receive(:configuration).and_return(config)
    allow(config).to receive(:output_dir).and_return(nil)
    stub_const('Woods::Extractor', double('extractor class', new: double(extract_all: nil, extract_changed: nil)))
    allow(Woods::Tasks).to receive(:build_embed_indexer)
      .and_return(double(index_all: nil, index_incremental: nil))
    allow(Woods::SessionTracer::SessionFlowAssembler).to receive(:new)
      .and_return(double(assemble: double(to_markdown: "## Session session-1\n1 request")))
    allow(Woods::Feedback::GapDetector).to receive(:new)
      .and_return(double(detect: [{ kind: 'missing_unit', count: 1 }]))
    allow(Woods::GraphAnalyzer).to receive(:new).and_return(
      double(domain_clusters: [{ name: 'Billing', member_count: 2, hub: 'PaymentService' }])
    )
    allow(Woods::Notion::Exporter).to receive(:new)
      .and_return(notion_exporter)
  end

  after { FileUtils.rm_rf(runtime_root) }

  def build_full_server
    Woods::MCP::Server.build(
      index_dir: fixture_dir,
      retriever: retriever,
      operator: operator,
      feedback_store: feedback_store,
      snapshot_store: snapshot_store,
      response_format: :json,
      warmup: false
    )
  end

  def contract(registration, arguments, result, required: [], properties: {}, effect: nil)
    {
      registration: registration,
      arguments: arguments,
      result: result,
      required: required,
      properties: properties,
      effect: effect
    }
  end

  def exact_data(data)
    { data: data }
  end

  def exact_text(text)
    { text: text }
  end

  def data_projection(*paths, key_sets: {}, types: {})
    { paths: paths, key_sets: key_sets, types: types }
  end

  def expected_counts
    {
      'models' => 2, 'controllers' => 1, 'graphql' => 0, 'components' => 0,
      'view_components' => 0, 'services' => 0, 'jobs' => 0, 'mailers' => 1,
      'serializers' => 0, 'decorators' => 1, 'concerns' => 1,
      'rails_source' => 2, 'libs' => 1
    }
  end

  def expected_manifest
    {
      'extracted_at' => '2026-01-15T12:00:00Z', 'rails_version' => '8.1.2',
      'ruby_version' => '4.0.1', 'counts' => expected_counts, 'total_units' => 9,
      'total_chunks' => 0, 'git_sha' => 'abc1234', 'git_branch' => 'main'
    }
  end

  def expected_graph_stats
    { 'orphan_count' => 1, 'dead_end_count' => 1, 'hub_count' => 3, 'cycle_count' => 0 }
  end

  def expected_graph_analysis
    {
      'orphans' => ['PostsController'],
      'dead_ends' => ['Post'],
      'hubs' => [
        { 'identifier' => 'Post', 'type' => 'model', 'dependent_count' => 2,
          'dependents' => %w[Comment PostsController] },
        { 'identifier' => 'Comment', 'type' => 'model', 'dependent_count' => 0, 'dependents' => [] },
        { 'identifier' => 'PostsController', 'type' => 'controller', 'dependent_count' => 0, 'dependents' => [] }
      ],
      'cycles' => [], 'bridges' => [], 'stats' => expected_graph_stats
    }
  end

  def expected_summary
    <<~SUMMARY
      # Codebase Index Summary
      Generated: 2026-01-15T12:00:00Z
      Rails 8.1.2 / Ruby 4.0.1

      ## Models (2)

      ### (root)
      - Comment
      - Post

      ## Controllers (1)

      ### (root)
      - PostsController
    SUMMARY
  end

  def integer_contract(minimum, maximum)
    { 'type' => 'integer', 'minimum' => minimum, 'maximum' => maximum }
  end

  def string_contract(minimum_length, maximum_length)
    { 'type' => 'string', 'minLength' => minimum_length, 'maxLength' => maximum_length }.compact
  end

  def array_contract(maximum_items, maximum_item_length)
    {
      'type' => 'array',
      'items' => { 'type' => 'string', 'maxLength' => maximum_item_length },
      'maxItems' => maximum_items
    }
  end

  def enum_array_contract(values, maximum_items, maximum_item_length)
    array_contract(maximum_items, maximum_item_length).tap do |contract|
      contract['items'] = contract.fetch('items').merge('enum' => values)
    end
  end

  def boolean_contract
    { 'type' => 'boolean' }
  end

  def enum_contract(values, minimum_length, maximum_length)
    string_contract(minimum_length, maximum_length).merge('enum' => values)
  end

  def union_contract
    {
      'anyOf' => [
        string_contract(nil, 10_000),
        array_contract(1_000, 10_000)
      ]
    }
  end

  def inventory_rows
    # encoding: pinned so the multibyte inventory JSON parses under LANG=C
    JSON.parse(File.read(inventory_path, encoding: Encoding::UTF_8)).dig('index_mcp', 'tools')
  end

  def assert_semantic_result(name, contract, result)
    expected = contract.fetch(:result)
    structured = result.fetch('structuredContent')
    assert_semantic_text(name, expected, result, structured)
    assert_semantic_data(name, expected, structured) if expected.key?(:data) || expected.key?(:paths)
  end

  def assert_semantic_text(name, expected, result, structured)
    expect(structured.fetch('text')).to eq(result.dig('content', 0, 'text')), name
    expect(structured.fetch('text')).to eq(expected.fetch(:text)), name if expected.key?(:text)
  end

  def assert_semantic_data(name, expected, structured)
    data = structured.fetch('data')
    expect(data).to eq(expected.fetch(:data)), name if expected.key?(:data)
    assert_projected_paths(name, expected, data)
    assert_projected_key_sets(name, expected, data)
    assert_projected_types(name, expected, data)
  end

  def assert_projected_paths(name, expected, data)
    expected.fetch(:paths, []).each do |path, value|
      expect(value_at(data, path)).to eq(value), "#{name}.#{path.join('.')}"
    end
  end

  def assert_projected_key_sets(name, expected, data)
    expected.fetch(:key_sets, {}).each do |path, keys|
      expect(value_at(data, path).keys).to contain_exactly(*keys), "#{name}.#{path.join('.')} keys"
    end
  end

  def assert_projected_types(name, expected, data)
    expected.fetch(:types, {}).each do |path, type|
      expect(value_at(data, path)).to be_a(type), "#{name}.#{path.join('.')} type"
    end
  end

  def value_at(value, path)
    path.reduce(value) { |current, key| current.respond_to?(:[]) ? current[key] : nil }
  end

  def prepare_contract(name, server)
    case contract_oracle.fetch(name).fetch(:effect)
    when :extraction_cooldown
      prepare_pipeline_cooldown(:extraction)
    when :embedding_cooldown
      prepare_pipeline_cooldown(:embedding)
    when :cooldowns_reset
      prepare_cooldowns_reset
    when :rating_persisted
      prepare_feedback_effect(:ratings)
    when :gap_persisted
      prepare_feedback_effect(:gaps)
    when :reloaded_manifest
      prepare_reloaded_manifest(server)
    else
      {}
    end
  end

  def prepare_pipeline_cooldown(operation)
    pipeline_guard.reset!(operation)
    { observe: -> { pipeline_guard.allow?(operation) } }
  end

  def prepare_cooldowns_reset
    pipeline_guard.record!(:extraction)
    pipeline_guard.record!(:embedding)
    { observe: -> { [pipeline_guard.allow?(:extraction), pipeline_guard.allow?(:embedding)] } }
  end

  def prepare_feedback_effect(collection)
    { before: feedback_store.public_send(collection).size, observe: -> { feedback_store.public_send(collection) } }
  end

  def prepare_reloaded_manifest(server)
    path = File.join(fixture_dir, 'manifest.json')
    original = File.binread(path)
    call_tool(server, 'structure', {})
    changed = expected_manifest.merge('total_units' => 10, 'counts' => expected_counts.merge('models' => 3))
    File.write(path, JSON.generate(changed))
    { original: original, observe: -> { served_manifest_total(server) } }
  end

  def served_manifest_total(server)
    call_tool(server, 'structure', {}).dig('result', 'structuredContent', 'data', 'manifest', 'total_units')
  end

  def assert_contract_effect(name, contract, context)
    case contract.fetch(:effect)
    when :extraction_cooldown, :embedding_cooldown
      expect(context.fetch(:observe).call).to be(false), "#{name} persisted cooldown"
    when :cooldowns_reset
      expect(context.fetch(:observe).call).to eq([true, true]), "#{name} reset cooldowns"
    when :rating_persisted
      assert_feedback_effect(context, 'type' => 'rating', 'query' => 'Post', 'score' => 4, 'comment' => nil)
    when :gap_persisted
      assert_feedback_effect(
        context,
        'type' => 'gap', 'query' => 'Post', 'missing_unit' => 'Post', 'unit_type' => 'model'
      )
    when :reloaded_manifest
      expect(context.fetch(:observe).call).to eq(10), 'reload changed the served manifest'
    end
  end

  def assert_feedback_effect(context, expected)
    entries = context.fetch(:observe).call
    expect(entries.size).to eq(context.fetch(:before) + 1)
    expect(entries.last.except('timestamp')).to eq(expected)
  end

  def cleanup_contract(contract, context)
    return unless contract.fetch(:effect) == :reloaded_manifest

    File.binwrite(File.join(fixture_dir, 'manifest.json'), context.fetch(:original))
  end

  def fake_result(data: nil, text: nil)
    text ||= JSON.generate(data)
    structured = { 'text' => text }
    structured['data'] = data unless data.nil?
    {
      'isError' => false,
      'content' => [{ 'type' => 'text', 'text' => text }],
      'structuredContent' => structured
    }
  end

  def assert_boundary_semantics(name, argument, value, result)
    data = result.dig('structuredContent', 'data')
    assertion = boundary_assertions[[name, argument]]
    return assert_semantic_result(name, contract_oracle.fetch(name), result) unless assertion

    send(assertion, data, value, name)
  end

  def boundary_assertions
    {
      %w[dependencies depth] => :assert_dependencies_depth,
      %w[dependents depth] => :assert_dependents_depth,
      %w[graph_analysis offset] => :assert_graph_offset,
      %w[pagerank limit] => :assert_limited_results,
      %w[recent_changes limit] => :assert_limited_results,
      %w[search limit] => :assert_limited_results,
      %w[retrieval_rate score] => :assert_rating_score,
      %w[trace_flow depth] => :assert_trace_depth
    }
  end

  def assert_dependencies_depth(data, value, _name)
    expected = value.zero? ? ['Comment'] : %w[Comment Post]
    expect(data.fetch('nodes').keys).to eq(expected)
    expect(data.dig('nodes', 'Comment', 'deps')).to eq(value.zero? ? [] : ['Post'])
  end

  def assert_dependents_depth(data, value, _name)
    expected = value.zero? ? ['Post'] : %w[Post Comment PostsController]
    expect(data.fetch('nodes').keys).to eq(expected)
    expect(data.dig('nodes', 'Post', 'deps')).to eq(value.zero? ? [] : %w[Comment PostsController])
  end

  def assert_graph_offset(data, value, _name)
    expected = if value.zero?
                 { 'orphans' => ['PostsController'], 'stats' => expected_graph_stats }
               else
                 { 'orphans' => [], 'stats' => expected_graph_stats, 'orphans_offset' => value }
               end
    expect(data).to eq(expected)
  end

  def assert_limited_results(data, value, name)
    expected = contract_oracle.fetch(name).dig(:result, :data)
    results = expected.fetch('results').first(value)
    expected = expected.merge('results' => results)
    expected = expected.merge('result_count' => results.size) if expected.key?('result_count')
    expect(data).to eq(expected)
  end

  def assert_rating_score(data, value, _name)
    expect(data).to eq('recorded' => true, 'type' => 'rating', 'query' => 'Post', 'score' => value)
  end

  # The fixture controller defines index/show but not create, so trace_flow's
  # expansion takes the documented named-but-undefined fallback: whole-unit
  # operations rather than a silently empty list. Depth >= 1 then follows the
  # Post call targets into the model step.
  def trace_flow_steps
    entry = {
      'unit' => 'PostsController#create', 'type' => 'controller',
      'file_path' => 'app/controllers/posts_controller.rb',
      'operations' => [
        { 'line' => 3, 'method' => 'all', 'target' => 'Post', 'type' => 'call' },
        { 'line' => 7, 'method' => 'find', 'target' => 'Post', 'type' => 'call' }
      ]
    }
    model = {
      'unit' => 'Post', 'type' => 'model', 'file_path' => 'app/models/post.rb',
      'operations' => [
        { 'line' => 2, 'method' => 'has_many', 'target' => nil, 'type' => 'call' },
        { 'line' => 3, 'method' => 'validates', 'target' => nil, 'type' => 'call' }
      ]
    }
    { entry_only: [entry], deep: [entry, model] }
  end

  def assert_trace_depth(data, value, _name)
    steps = value.zero? ? trace_flow_steps.fetch(:entry_only) : trace_flow_steps.fetch(:deep)
    expect(data.except('generated_at')).to eq(
      'entry_point' => 'PostsController#create', 'route' => nil, 'max_depth' => value,
      'steps' => steps
    )
  end

  def prepare_enum_semantics(name, value)
    return unless name == 'pipeline_repair'

    if value == 'clear_locks'
      holder = Woods::Coordination::PipelineLock.new(
        lock_dir: File.join(runtime_root, 'operator'), name: 'extraction', stale_timeout: 60
      )
      raise 'could not seed stale repair lock' unless holder.acquire

      path = File.join(runtime_root, 'operator', 'extraction.lock')
      File.utime(Time.now - 120, Time.now - 120, path)
    else
      pipeline_guard.record!(:extraction)
    end
  end

  def assert_enum_semantics(name, value, result)
    data = result.dig('structuredContent', 'data')
    case name
    when 'graph_analysis'
      assert_graph_enum(data, value)
    when 'pipeline_repair'
      outcome = value == 'clear_locks' ? 'cleared' : 'reset'
      expect(data).to eq('repaired' => true, 'action' => value, 'outcome' => outcome)
    when 'structure'
      expected = { 'manifest' => expected_manifest, 'template_engines' => ['erb'] }
      expected['summary'] = expected_summary if value == 'full'
      expect(data).to eq(expected)
    else
      raise "Missing enum semantic oracle for #{name}.#{value}"
    end
  end

  def assert_graph_enum(data, value)
    expected = if value == 'all'
                 expected_graph_analysis
               else
                 { value => expected_graph_analysis.fetch(value), 'stats' => expected_graph_stats }
               end
    expect(data).to eq(expected)
  end

  def assert_union_semantics(name, result)
    root, type = name == 'dependencies' ? %w[Comment model] : %w[Post model]
    expect(result.dig('structuredContent', 'data')).to eq(
      'root' => root,
      'found' => true,
      'nodes' => { root => { 'type' => type, 'depth' => 0, 'deps' => [] } }
    )
  end

  def rpc(server, method, params = {})
    params = params.merge('_meta' => tool_contract_meta) unless method == 'server/discover'
    raw = server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: method, params: params))
    JSON.parse(raw)
  end

  def listed_tools(server)
    rpc(server, 'tools/list').dig('result', 'tools')
  end

  def call_tool(server, name, arguments)
    rpc(server, 'tools/call', 'name' => name, 'arguments' => arguments)
  end

  def wait_for_pipeline(tool_name)
    kind = { 'pipeline_extract' => :extraction, 'pipeline_embed' => :embedding }[tool_name]
    return unless kind

    Timeout.timeout(2) do
      in_flight = Woods::MCP::Server.instance_variable_get(:@pipeline_in_flight)
      sleep 0.005 while in_flight[kind]
    end
  end

  def wrong_value(schema)
    return false if schema['anyOf']

    {
      'array' => {},
      'boolean' => 'true',
      'integer' => 'one',
      'string' => false
    }.fetch(schema.fetch('type'))
  end

  def projected_schema(schema, expected)
    schema.slice(*expected.keys).tap do |projected|
      projected['anyOf'] = schema['anyOf'] if expected.key?('anyOf')
    end
  end

  it 'keeps code-derived inventory as a separate drift input to the independent oracle' do
    expect(inventory_rows.size).to eq(29)
    expect(inventory_rows.map { |row| row.fetch('name') }).to contain_exactly(*contract_oracle.keys)
    expect(listed_tools(full_server).map { |tool| tool.fetch('name') })
      .to contain_exactly(*contract_oracle.keys)
  end

  it 'proves exact semantic facts and schema-valid success for every explicit tool contract' do
    schemas = listed_tools(full_server).to_h { |tool| [tool.fetch('name'), tool['outputSchema']] }

    aggregate_failures do
      contract_oracle.each do |name, contract|
        contract_server = build_full_server
        context = prepare_contract(name, contract_server)
        begin
          result = call_tool(contract_server, name, contract.fetch(:arguments)).fetch('result')
          wait_for_pipeline(name)

          expect(result['isError']).to be(false), name
          assert_semantic_result(name, contract, result)
          assert_contract_effect(name, contract, context)
          schema = schemas.fetch(name)
          next unless schema

          expect do
            MCP::Tool::OutputSchema.new(schema).validate_result(result.fetch('structuredContent'))
          end.not_to raise_error, name
        ensure
          cleanup_contract(contract, context)
        end
      end
    end
  end

  it 'rejects generic, empty, fabricated, and no-op payloads in the semantic harness' do
    generic = fake_result(data: { 'ok' => true })
    contract_oracle.each do |name, contract|
      expect { assert_semantic_result(name, contract, generic) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError), name
    end

    expect do
      assert_semantic_result(
        'domain_clusters', contract_oracle.fetch('domain_clusters'),
        fake_result(data: { 'clusters' => [], 'total' => 0 })
      )
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError)
    expect do
      assert_semantic_result(
        'pipeline_status', contract_oracle.fetch('pipeline_status'),
        fake_result(data: { 'status' => 'ok' })
      )
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError)

    reload_contract = contract_oracle.fetch('reload')
    assert_semantic_result('reload', reload_contract, fake_result(data: reload_contract.dig(:result, :data)))
    expect do
      assert_contract_effect('reload', reload_contract, observe: -> { 9 })
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError)

    repair_contract = contract_oracle.fetch('pipeline_repair')
    assert_semantic_result(
      'pipeline_repair', repair_contract, fake_result(data: repair_contract.dig(:result, :data))
    )
    expect do
      assert_contract_effect('pipeline_repair', repair_contract, observe: -> { [false, false] })
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError)
  end

  it 'proves the explicit side effects for mutating and collaborator-backed tools' do
    %w[pipeline_extract pipeline_embed retrieval_rate retrieval_report_gap notion_sync
       list_snapshots snapshot_diff unit_history snapshot_detail].each do |name|
      call_tool(full_server, name, contract_oracle.fetch(name).fetch(:arguments))
      wait_for_pipeline(name)
    end

    expect(pipeline_guard.allow?(:extraction)).to be(false)
    expect(pipeline_guard.allow?(:embedding)).to be(false)
    expect(feedback_store.ratings.last.except('timestamp')).to eq(
      'type' => 'rating', 'query' => 'Post', 'score' => 4, 'comment' => nil
    )
    expect(feedback_store.gaps.last.except('timestamp')).to eq(
      'type' => 'gap', 'query' => 'Post', 'missing_unit' => 'Post', 'unit_type' => 'model'
    )
    expect(notion_exporter).to have_received(:sync_all)
    expect(snapshot_store).to have_received(:list).with(limit: 20, branch: nil)
    expect(snapshot_store).to have_received(:diff).with('aaa111', 'bbb222')
    expect(snapshot_store).to have_received(:unit_history).with('Post', limit: 20)
    expect(snapshot_store).to have_received(:find).with('aaa111')
    call_tool(full_server, 'pipeline_repair', 'action' => 'reset_cooldowns')
    expect(pipeline_guard.allow?(:extraction)).to be(true)
    expect(pipeline_guard.allow?(:embedding)).to be(true)
  end

  it 'exercises each explicit dependency class independently' do
    dependency_servers = {
      always: -> { Woods::MCP::Server.build(index_dir: fixture_dir, response_format: :json, warmup: false) },
      operator: -> { Woods::MCP::Server.build(index_dir: fixture_dir, operator: operator, warmup: false) },
      feedback: -> { Woods::MCP::Server.build(index_dir: fixture_dir, feedback_store: feedback_store, warmup: false) },
      snapshot: -> { Woods::MCP::Server.build(index_dir: fixture_dir, snapshot_store: snapshot_store, warmup: false) }
    }

    aggregate_failures do
      dependency_servers.each do |dependency, build|
        allow(Woods).to receive(:configuration).and_return(Woods::Configuration.new)
        expected = contract_oracle.filter_map do |name, entry|
          name if %i[always].include?(entry.fetch(:registration)) || entry.fetch(:registration) == dependency
        end
        expect(listed_tools(build.call).map { |tool| tool.fetch('name') })
          .to contain_exactly(*expected), dependency.to_s
      end

      session_config = Woods::Configuration.new
      session_config.session_store = config.session_store
      allow(Woods).to receive(:configuration).and_return(session_config)
      session = Woods::MCP::Server.build(index_dir: fixture_dir, warmup: false)
      expected_session = contract_oracle.filter_map do |name, entry|
        name if %i[always session].include?(entry.fetch(:registration))
      end
      expect(listed_tools(session).map { |tool| tool.fetch('name') }).to contain_exactly(*expected_session)

      notion_config = Woods::Configuration.new
      notion_config.notion_api_token = 'test-token'
      notion_config.notion_database_ids = { data_models: 'test-database' }
      allow(Woods).to receive(:configuration).and_return(notion_config)
      notion = Woods::MCP::Server.build(index_dir: fixture_dir, warmup: false)
      expected_notion = contract_oracle.filter_map do |name, entry|
        name if %i[always notion].include?(entry.fetch(:registration))
      end
      expect(listed_tools(notion).map { |tool| tool.fetch('name') }).to contain_exactly(*expected_notion)
    end
  end

  it 'returns stable unavailability errors for every collaborator-gated row' do
    lean_config = Woods::Configuration.new
    allow(Woods).to receive(:configuration).and_return(lean_config)
    lean = Woods::MCP::Server.build(index_dir: fixture_dir, response_format: :json, warmup: false)
    unavailable = contract_oracle.reject { |_name, contract| contract.fetch(:registration) == :always }

    aggregate_failures do
      unavailable.each_key do |name|
        response = call_tool(lean, name, {})
        expect(response.dig('error', 'code')).to eq(-32_602), name
        expect(response.dig('error', 'data')).to include(name), name
      end
    end
  end

  it 'returns stable not-configured metadata for present tools with missing nested collaborators' do
    partial = Woods::MCP::Server.build(
      index_dir: fixture_dir,
      operator: {},
      response_format: :json,
      warmup: false
    )
    calls = {
      'pipeline_status' => {},
      'pipeline_diagnose' => { 'error_class' => 'Timeout::Error', 'error_message' => 'timed out' },
      'pipeline_repair' => { 'action' => 'clear_locks' }
    }

    aggregate_failures do
      calls.each do |name, arguments|
        result = call_tool(partial, name, arguments).fetch('result')
        expect(result['isError']).to be(true), name
        expect(result.dig('_meta', 'error_code')).to eq('not_configured'), name
      end
    end
  end

  it 'keeps codebase_retrieve registered with a typed fallback when retrieval is unavailable' do
    unavailable = Woods::MCP::Server.build(
      index_dir: fixture_dir,
      response_format: :json,
      warmup: false
    )
    result = call_tool(unavailable, 'codebase_retrieve', 'query' => 'Post').fetch('result')

    expect(result['isError']).to be(true)
    expect(result.dig('_meta', 'error_code')).to eq('not_configured')
    expect(result.dig('_meta', 'config_key')).to eq('embedding_provider')
  end

  it 'publishes closed input schemas and non-vacuous output schemas for every row' do
    aggregate_failures do
      listed_tools(full_server).each do |tool|
        input = tool.fetch('inputSchema')

        expect(input['type']).to eq('object'), tool.fetch('name')
        expect(input['additionalProperties']).to be(false), tool.fetch('name')
        if Woods::MCP::ToolContract::TASK_RESULT_TOOLS.include?(tool.fetch('name'))
          expect(tool).not_to have_key('outputSchema')
          next
        end

        output = tool.fetch('outputSchema')
        expect(output).to include(
          'type' => 'object',
          'required' => ['text'],
          'additionalProperties' => false
        ), tool.fetch('name')
        expect(output.dig('properties', 'text')).to eq('type' => 'string'), tool.fetch('name')
      end
    end
  end

  it 'matches every runtime argument to the fully literal oracle' do
    aggregate_failures do
      listed_tools(full_server).each do |tool|
        expected = contract_oracle.fetch(tool.fetch('name'))
        schema = tool.fetch('inputSchema')
        expect(schema.fetch('required', [])).to eq(expected.fetch(:required)), tool.fetch('name')
        expect(schema.fetch('properties').keys)
          .to contain_exactly(*expected.fetch(:properties).keys), tool.fetch('name')
        expected.fetch(:properties).each do |name, property|
          expect(projected_schema(schema.fetch('properties').fetch(name), property))
            .to eq(property), "#{tool.fetch('name')}.#{name}"
        end
      end
    end
  end

  it 'rejects unknown arguments for every row with stable tool error metadata' do
    aggregate_failures do
      contract_oracle.each do |name, contract|
        arguments = contract.fetch(:arguments).merge('__unknown' => true)
        result = call_tool(full_server, name, arguments).fetch('result')
        expect(result['isError']).to be(true), name
        expect(result.dig('_meta', 'error_code')).to eq('invalid_arguments'), name
      end
    end
  end

  it 'rejects non-object arguments for every row without an internal error' do
    aggregate_failures do
      contract_oracle.each_key do |name|
        response = call_tool(full_server, name, [])
        expect(response['error']).to be_nil, name
        expect(response.dig('result', 'isError')).to be(true), name
        expect(response.dig('result', '_meta', 'error_code')).to eq('invalid_arguments'), name
      end
    end
  end

  it 'rejects every declared argument at the wrong JSON type with stable metadata' do
    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        contract.fetch(:properties).each do |name, property|
          arguments = contract.fetch(:arguments).merge(name => wrong_value(property))
          result = call_tool(full_server, tool_name, arguments).fetch('result')

          expect(result['isError']).to be(true), "#{tool_name}.#{name}"
          expect(result.dig('_meta', 'error_code')).to eq('invalid_arguments'), "#{tool_name}.#{name}"
        end
      end
    end
  end

  it 'accepts inclusive integer boundaries and rejects values immediately outside them' do
    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        contract.fetch(:properties).each do |name, property|
          next unless property['type'] == 'integer'

          [property.fetch('minimum'), property.fetch('maximum')].each do |value|
            arguments = contract.fetch(:arguments).merge(name => value)
            result = call_tool(full_server, tool_name, arguments).fetch('result')
            label = "#{tool_name}.#{name}=#{value}"
            expect(result['isError']).to be(false), label
            assert_boundary_semantics(tool_name, name, value, result)
          end

          [property.fetch('minimum') - 1, property.fetch('maximum') + 1].each do |value|
            arguments = contract.fetch(:arguments).merge(name => value)
            result = call_tool(full_server, tool_name, arguments).fetch('result')
            label = "#{tool_name}.#{name}=#{value}"
            expect(result['isError']).to be(true), label
            expect(result.dig('_meta', 'error_code')).to eq('invalid_arguments'), label
            expect(result.dig('content', 0, 'text')).to include(name), label
          end
        end
      end
    end
  end

  it 'declares and executes every documented string-or-array union' do
    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        contract.fetch(:properties).each do |name, property|
          next unless property['anyOf']

          string_result = call_tool(
            full_server, tool_name, contract.fetch(:arguments).merge(name => 'code_reference')
          )
          array_result = call_tool(
            full_server, tool_name, contract.fetch(:arguments).merge(name => ['code_reference'])
          )
          expect(string_result.dig('result', 'isError')).to be(false), "#{tool_name}.#{name} string"
          expect(array_result.dig('result', 'isError')).to be(false), "#{tool_name}.#{name} array"
          expect(string_result.dig('result', 'structuredContent', 'data'))
            .to eq(array_result.dig('result', 'structuredContent', 'data'))
          assert_union_semantics(tool_name, string_result.fetch('result'))
          invalid = call_tool(full_server, tool_name, contract.fetch(:arguments).merge(name => false)).fetch('result')
          expect(invalid['isError']).to be(true), "#{tool_name}.#{name} invalid"
          expect(invalid.dig('_meta', 'error_code')).to eq('invalid_arguments'), "#{tool_name}.#{name} invalid"
          expect(invalid.dig('content', 0, 'text')).to include(name), "#{tool_name}.#{name} invalid"
        end
      end
    end
  end

  it 'bounds every explicitly enumerated string and array argument' do
    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        contract.fetch(:properties).each do |name, property|
          next unless %w[string array].include?(property['type'])

          expected = property['type'] == 'string' ? property.fetch('maxLength') : property.fetch('maxItems')
          expect(expected).to be_positive, "#{tool_name}.#{name}"
        end
      end
    end
  end

  it 'accepts exact string/array maxima and rejects the adjacent overflow for every oracle entry' do
    tools = listed_tools(full_server).to_h { |tool| [tool.fetch('name'), tool] }

    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        input = MCP::Tool::InputSchema.new(tools.fetch(tool_name).fetch('inputSchema'))
        contract.fetch(:properties).each do |name, property|
          case property['type']
          when 'string'
            next if property['enum']

            maximum = property.fetch('maxLength')
            valid = contract.fetch(:arguments).merge(name => 'x' * maximum)
            invalid = contract.fetch(:arguments).merge(name => 'x' * (maximum + 1))
            expect { input.validate_arguments(valid) }.not_to raise_error, "#{tool_name}.#{name}=#{maximum}"
            expect { input.validate_arguments(invalid) }
              .to raise_error(MCP::Tool::InputSchema::ValidationError), "#{tool_name}.#{name}=#{maximum + 1}"
          when 'array'
            maximum = property.fetch('maxItems')
            item_maximum = property.dig('items', 'maxLength')
            item = property.dig('items', 'enum')&.first || 'x'
            valid = contract.fetch(:arguments).merge(name => Array.new(maximum, item))
            too_many = contract.fetch(:arguments).merge(name => Array.new(maximum + 1, item))
            long_item = contract.fetch(:arguments).merge(name => ['x' * (item_maximum + 1)])
            expect { input.validate_arguments(valid) }.not_to raise_error, "#{tool_name}.#{name}=#{maximum}"
            expect { input.validate_arguments(too_many) }
              .to raise_error(MCP::Tool::InputSchema::ValidationError), "#{tool_name}.#{name}=#{maximum + 1}"
            expect { input.validate_arguments(long_item) }
              .to raise_error(MCP::Tool::InputSchema::ValidationError), "#{tool_name}.#{name} item=#{item_maximum + 1}"
          end
        end
      end
    end
  end

  it 'accepts and rejects every explicitly enumerated value set' do
    aggregate_failures do
      contract_oracle.each do |tool_name, contract|
        contract.fetch(:properties).each do |name, property|
          next unless property['enum']

          property.fetch('enum').each do |value|
            prepare_enum_semantics(tool_name, value)
            result = call_tool(
              full_server, tool_name, contract.fetch(:arguments).merge(name => value)
            ).fetch('result')
            expect(result['isError']).to be(false), "#{tool_name}.#{name}=#{value}"
            assert_enum_semantics(tool_name, value, result)
          end
          result = call_tool(
            full_server, tool_name, contract.fetch(:arguments).merge(name => '__invalid__')
          ).fetch('result')
          expect(result['isError']).to be(true), "#{tool_name}.#{name}=invalid"
          expect(result.dig('_meta', 'error_code')).to eq('invalid_arguments'), "#{tool_name}.#{name}=invalid"
          expect(result.dig('content', 0, 'text')).to include(name), "#{tool_name}.#{name}=invalid"
        end
      end
    end
  end

  it 'rejects missing schema-required arguments with stable metadata' do
    aggregate_failures do
      contract_oracle.each do |name, contract|
        next if contract.fetch(:required).empty?

        result = call_tool(full_server, name, {}).fetch('result')
        expect(result['isError']).to be(true), name
        expect(result.dig('_meta', 'error_code')).to eq('missing_required_arguments'), name
      end
    end
  end

  it 'names the bounds table and the property when an integer argument has no INTEGER_BOUNDS entry' do
    server = MCP::Server.new(name: 'woods-bounds-probe', version: Woods::VERSION)
    server.define_tool(
      name: 'bounds_probe',
      input_schema: { properties: { count: { type: 'integer' } } }
    ) { |server_context:, count: nil| [server_context, count] }

    expect { Woods::MCP::ToolContract.apply!(server) }.to raise_error(ArgumentError) do |error|
      expect(error.message).to include('INTEGER_BOUNDS').and include('count').and include('bounds_probe')
    end
  end

  it 'rejects an unknown search field instead of answering with a clean empty result' do
    result = call_tool(full_server, 'search', { 'query' => 'Post', 'fields' => ['bogus'] }).fetch('result')

    expect(result['isError']).to be(true)
    expect(result.dig('_meta', 'error_code')).to eq('invalid_arguments')
    expect(result.dig('content', 0, 'text')).to include('fields')
  end

  it 'returns schema-valid structured content alongside text' do
    tool = listed_tools(full_server).find { |entry| entry.fetch('name') == 'woods_status' }
    result = call_tool(full_server, 'woods_status', {}).fetch('result')
    schema = MCP::Tool::OutputSchema.new(tool.fetch('outputSchema'))

    expect(result.dig('structuredContent', 'text')).to eq(result.dig('content', 0, 'text'))
    expect(result.dig('structuredContent', 'data')).to be_a(Hash)
    expect { schema.validate_result(result.fetch('structuredContent')) }.not_to raise_error
  end
end
