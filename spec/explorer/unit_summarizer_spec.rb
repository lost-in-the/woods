# frozen_string_literal: true

require 'spec_helper'
require 'woods/explorer/unit_summarizer'

RSpec.describe Woods::Explorer::UnitSummarizer do
  def facts_for(unit)
    described_class.new(unit).facts
  end

  describe '#facts for a model unit' do
    let(:metadata) do
      {
        'loc' => 42,
        'git' => { 'change_frequency' => 7, 'last_author' => 'leah', 'last_modified' => '2026-01-02' },
        'table_name' => 'posts',
        'columns' => [
          { 'name' => 'id', 'type' => 'integer', 'null' => false },
          { 'name' => 'title', 'type' => 'string', 'null' => true }
        ],
        'associations' => [
          { 'name' => 'comments', 'type' => 'has_many', 'target' => 'Comment',
            'options' => { 'dependent' => 'destroy' } },
          { 'name' => 'user', 'type' => 'belongs_to', 'target' => 'User',
            'options' => { 'optional' => true } },
          { 'name' => 'tags', 'type' => 'has_many', 'target' => 'Tag', 'through' => 'taggings' },
          { 'name' => 'taggable', 'type' => 'belongs_to', 'polymorphic' => true }
        ],
        'validations' => [
          { 'attribute' => 'title', 'type' => 'presence' },
          { 'attribute' => %w[slug title], 'type' => 'uniqueness' }
        ],
        'callbacks' => [
          { 'type' => 'after_save', 'filter' => 'schedule_publish',
            'side_effects' => { 'jobs_enqueued' => ['PublishPostJob'], 'columns_written' => [] } },
          { 'type' => 'before_save', 'filter' => 'normalize_title', 'side_effects' => nil },
          { 'type' => 'after_create', 'filter' => 'audit',
            'side_effects' => { 'columns_written' => [], 'jobs_enqueued' => [] } }
        ],
        'scopes' => [{ 'name' => 'recent' }, 'published'],
        'enums' => { 'status' => { 'draft' => 0, 'published' => 1 } },
        'inlined_concerns' => ['Sluggable']
      }
    end

    let(:unit) { { 'identifier' => 'Post', 'type' => 'model', 'metadata' => metadata } }
    let(:facts) { facts_for(unit) }

    it 'carries the table name and common git facts' do
      expect(facts).to include('table_name' => 'posts', 'loc' => 42, 'change_frequency' => 7,
                               'last_author' => 'leah', 'last_modified' => '2026-01-02')
    end

    it 'normalizes columns and records the true total' do
      expect(facts['columns']).to eq([{ 'name' => 'id', 'type' => 'integer', 'null' => false },
                                      { 'name' => 'title', 'type' => 'string', 'null' => true }])
      expect(facts['columns_total']).to eq(2)
    end

    it 'renames association type to macro and keeps through/polymorphic/dependent/optional' do
      expect(facts['associations']).to contain_exactly(
        { 'name' => 'comments', 'macro' => 'has_many', 'target' => 'Comment', 'dependent' => 'destroy' },
        { 'name' => 'user', 'macro' => 'belongs_to', 'target' => 'User', 'optional' => true },
        { 'name' => 'tags', 'macro' => 'has_many', 'target' => 'Tag', 'through' => 'taggings' },
        { 'name' => 'taggable', 'macro' => 'belongs_to', 'polymorphic' => true }
      )
    end

    it 'renders validations as "attr: type" strings, joining multi-attribute rules' do
      expect(facts['validations']).to eq(['title: presence', 'slug, title: uniqueness'])
    end

    it 'keeps callback side_effects only when a non-empty effect list exists' do
      expect(facts['callbacks']).to eq([
                                         { 'type' => 'after_save', 'filter' => 'schedule_publish',
                                           'side_effects' => { 'jobs_enqueued' => ['PublishPostJob'] } },
                                         { 'type' => 'before_save', 'filter' => 'normalize_title' },
                                         { 'type' => 'after_create', 'filter' => 'audit' }
                                       ])
    end

    it 'extracts scope names from both hash and bare-string entries' do
      expect(facts['scopes']).to eq(%w[recent published])
    end

    it 'transforms enums into value-name lists' do
      expect(facts['enums']).to eq('status' => %w[draft published])
    end

    it 'omits sti facts for a non-STI model' do
      expect(facts).not_to have_key('sti')
    end

    it 'reports sti facts when STI flags are present' do
      sti = facts_for(unit.merge('metadata' => metadata.merge('is_sti_base' => true)))
      expect(sti['sti']).to eq('base' => true)
    end
  end

  describe '#facts for a controller unit' do
    let(:unit) do
      { 'type' => 'controller',
        'metadata' => {
          'actions' => %w[index show],
          'routes' => { 'index' => [{ 'verb' => 'GET', 'path' => '/posts' }],
                        'show' => [{ 'verb' => 'GET', 'path' => '/posts/:id' }, 'bogus'] },
          'filters' => [{ 'kind' => 'before_action', 'filter' => 'authenticate', 'only' => %w[show edit] },
                        { 'kind' => 'after_action', 'filter' => 'log_visit', 'except' => %w[index] },
                        'junk'],
          'permitted_params' => { 'create' => { 'permitted' => %w[title body] }, 'update' => %w[title] }
        } }
    end

    let(:facts) { facts_for(unit) }

    it 'lists the actions' do
      expect(facts['actions']).to eq(%w[index show])
    end

    it 'renders route map values as "VERB /path" strings, skipping malformed entries' do
      expect(facts['routes']).to eq('index' => ['GET /posts'], 'show' => ['GET /posts/:id'])
    end

    it 'renders filters as "kind filter only=..." strings' do
      expect(facts['filters']).to eq(['before_action authenticate only=show,edit',
                                      'after_action log_visit except=index'])
    end

    it 'normalizes permitted params from both hash and array shapes' do
      expect(facts['permitted_params']).to eq('create' => %w[title body], 'update' => %w[title])
    end
  end

  describe '#facts for a route unit' do
    it 'carries verb, path, controller, action, and route name' do
      unit = { 'type' => 'route',
               'metadata' => { 'http_method' => 'GET', 'path' => '/posts', 'controller' => 'posts',
                               'action' => 'index', 'route_name' => 'posts' } }
      expect(facts_for(unit)).to include('verb' => 'GET', 'path' => '/posts', 'controller' => 'posts',
                                         'action' => 'index', 'route_name' => 'posts')
    end
  end

  describe '#facts for a job unit' do
    it 'extracts perform param names from hash entries' do
      unit = { 'type' => 'job',
               'metadata' => { 'queue' => 'default',
                               'perform_params' => [{ 'name' => 'post', 'kind' => 'req' }, 'raw'],
                               'retry_on' => %w[Timeout::Error], 'enqueues_jobs' => %w[FollowUpJob] } }
      facts = facts_for(unit)
      expect(facts).to include('queue' => 'default', 'perform_params' => %w[post raw],
                               'retry_on' => %w[Timeout::Error], 'enqueues' => %w[FollowUpJob])
    end
  end

  describe '#facts for a view unit' do
    it 'carries engine, partial flag, renders, helpers, and ivars' do
      unit = { 'type' => 'view_template',
               'metadata' => { 'template_engine' => 'erb', 'is_partial' => true,
                               'partials_rendered' => %w[posts/form], 'helpers_called' => %w[link_to],
                               'instance_variables' => %w[@post] } }
      expect(facts_for(unit)).to include('engine' => 'erb', 'partial' => true, 'renders' => %w[posts/form],
                                         'helpers' => %w[link_to], 'ivars' => %w[@post])
    end
  end

  describe '#facts generic fallback' do
    let(:unit) do
      { 'type' => 'migration',
        'metadata' => { 'version' => '20260101010101', 'reversible' => false, 'statement_count' => 3,
                        'tables' => ['posts', 7, { 'nope' => 1 }],
                        'nested' => { 'a' => 1 },
                        'git' => { 'change_frequency' => 9 } } }
    end

    let(:facts) { facts_for(unit) }

    it 'keeps scalars and the string members of arrays' do
      expect(facts).to include('version' => '20260101010101', 'reversible' => false,
                               'statement_count' => 3, 'tables' => %w[posts])
    end

    it 'drops the git blob and nested hashes' do
      expect(facts).not_to have_key('git')
      expect(facts).not_to have_key('nested')
    end
  end

  describe 'list capping' do
    it 'caps every list at LIST_CAP and records the real column total' do
      names = (1..61).map { |i| "col_#{i}" }
      unit = { 'type' => 'model',
               'metadata' => { 'columns' => names.map { |n| { 'name' => n, 'type' => 'string' } },
                               'scopes' => names } }
      facts = facts_for(unit)
      expect(facts['columns'].size).to eq(described_class::LIST_CAP)
      expect(facts['columns_total']).to eq(61)
      expect(facts['scopes'].size).to eq(60)
    end
  end

  describe 'truncation totals' do
    it 'records <key>_total alongside any truncated list' do
      meta = { 'scopes' => Array.new(65) { |i| { 'name' => format('scope_%d', i) } } }
      facts = described_class.new({ 'type' => 'model', 'metadata' => meta }).facts

      expect(facts['scopes'].size).to eq(described_class::LIST_CAP)
      expect(facts['scopes_total']).to eq(65)
    end

    it 'adds no total for lists within the cap' do
      meta = { 'scopes' => [{ 'name' => 'recent' }] }
      facts = described_class.new({ 'type' => 'model', 'metadata' => meta }).facts

      expect(facts).not_to have_key('scopes_total')
    end
  end

  describe '#summary_line' do
    it 'summarizes a model by its structural counts' do
      unit = { 'type' => 'model',
               'metadata' => { 'columns' => [{ 'name' => 'id' }, { 'name' => 'title' }],
                               'associations' => [{ 'name' => 'user', 'type' => 'belongs_to' }],
                               'callbacks' => [{ 'type' => 'before_save', 'filter' => 'x' }],
                               'scopes' => %w[recent] } }
      expect(described_class.new(unit).summary_line)
        .to eq('2 columns · 1 association · 1 callback · 1 scope')
    end

    it 'summarizes a route as "VERB /path"' do
      unit = { 'type' => 'route', 'metadata' => { 'http_method' => 'GET', 'path' => '/posts' } }
      expect(described_class.new(unit).summary_line).to eq('GET /posts')
    end

    it 'falls back to the unit type when metadata yields nothing' do
      unit = { 'type' => 'engine', 'metadata' => {} }
      expect(described_class.new(unit).summary_line).to eq('engine')
    end
  end

  describe 'malformed input' do
    it 'never raises for a nil unit' do
      summarizer = described_class.new(nil)
      expect { summarizer.facts }.not_to raise_error
      expect(summarizer.facts).to eq({})
      expect { summarizer.summary_line }.not_to raise_error
    end

    it 'treats non-hash metadata as empty' do
      summarizer = described_class.new('type' => 'model', 'metadata' => 'corrupted')
      expect { summarizer.facts }.not_to raise_error
      expect(summarizer.facts['columns_total']).to eq(0)
    end

    it 'skips non-hash entries inside associations, callbacks, and validations' do
      unit = { 'type' => 'model',
               'metadata' => { 'associations' => ['bogus', 42, nil],
                               'callbacks' => [17], 'validations' => [nil] } }
      facts = facts_for(unit)
      expect(facts['associations']).to eq([])
      expect(facts['callbacks']).to eq([])
      expect(facts['validations']).to eq([])
    end
  end
end
