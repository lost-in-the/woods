# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/flow_document'

RSpec.describe CodebaseIndex::FlowDocument do
  let(:steps) do
    [
      {
        unit: 'PostsController#create',
        type: 'controller',
        file_path: 'app/controllers/posts_controller.rb',
        operations: [
          { type: :call, target: 'PostService', method: 'call', line: 10 },
          { type: :async, target: 'NotifyWorker', method: 'perform_async', args_hint: ['post.id'], line: 12 },
          { type: :response, status_code: 201, render_method: 'render_created', line: 14 }
        ]
      },
      {
        unit: 'PostService',
        type: 'service',
        file_path: 'app/services/post_service.rb',
        operations: [
          { type: :transaction, receiver: 'Post', line: 5, nested: [
            { type: :call, target: 'Post', method: 'create!', line: 6 }
          ] }
        ]
      }
    ]
  end

  let(:route) { { verb: 'POST', path: '/posts' } }
  let(:generated_at) { '2026-02-13T10:00:00+00:00' }

  let(:doc) do
    described_class.new(
      entry_point: 'PostsController#create',
      route: route,
      max_depth: 5,
      steps: steps,
      generated_at: generated_at
    )
  end

  describe '#initialize' do
    it 'stores all attributes' do
      expect(doc.entry_point).to eq('PostsController#create')
      expect(doc.route).to eq(route)
      expect(doc.max_depth).to eq(5)
      expect(doc.steps).to eq(steps)
      expect(doc.generated_at).to eq(generated_at)
    end

    it 'defaults generated_at to current time' do
      doc = described_class.new(entry_point: 'Foo#bar')
      expect(doc.generated_at).to be_a(String)
    end

    it 'defaults max_depth to 5' do
      doc = described_class.new(entry_point: 'Foo#bar')
      expect(doc.max_depth).to eq(5)
    end
  end

  describe '#to_h' do
    it 'returns a JSON-serializable hash' do
      hash = doc.to_h

      expect(hash[:entry_point]).to eq('PostsController#create')
      expect(hash[:route]).to eq(route)
      expect(hash[:max_depth]).to eq(5)
      expect(hash[:generated_at]).to eq(generated_at)
      expect(hash[:steps]).to eq(steps)
    end

    it 'round-trips through JSON' do
      json = JSON.generate(doc.to_h)
      parsed = JSON.parse(json)

      expect(parsed['entry_point']).to eq('PostsController#create')
      expect(parsed['max_depth']).to eq(5)
      expect(parsed['steps'].size).to eq(2)
    end
  end

  describe '.from_h' do
    it 'reconstructs from symbol-keyed hash' do
      restored = described_class.from_h(doc.to_h)

      expect(restored.entry_point).to eq('PostsController#create')
      expect(restored.route).to eq(route)
      expect(restored.max_depth).to eq(5)
      expect(restored.generated_at).to eq(generated_at)
      expect(restored.steps).to eq(steps)
    end

    it 'reconstructs from string-keyed hash (JSON round-trip)' do
      json = JSON.generate(doc.to_h)
      parsed = JSON.parse(json)
      restored = described_class.from_h(parsed)

      expect(restored.entry_point).to eq('PostsController#create')
      expect(restored.max_depth).to eq(5)
      expect(restored.steps.size).to eq(2)
    end

    it 'handles missing optional fields' do
      restored = described_class.from_h({ entry_point: 'Foo' })

      expect(restored.entry_point).to eq('Foo')
      expect(restored.route).to be_nil
      expect(restored.max_depth).to eq(5)
      expect(restored.steps).to eq([])
    end
  end

  describe '#to_markdown' do
    it 'includes the route header' do
      md = doc.to_markdown
      expect(md).to include('## POST /posts')
      expect(md).to include('PostsController#create')
    end

    it 'includes step sections with unit names' do
      md = doc.to_markdown
      expect(md).to include('### 1. PostsController#create')
      expect(md).to include('### 2. PostService')
    end

    it 'includes file paths' do
      md = doc.to_markdown
      expect(md).to include('_app/controllers/posts_controller.rb_')
    end

    it 'includes the operations table' do
      md = doc.to_markdown
      expect(md).to include('| # | Operation | Target | Line |')
      expect(md).to include('PostService.call')
    end

    it 'renders async operations with args' do
      md = doc.to_markdown
      expect(md).to include('async')
      expect(md).to include('NotifyWorker.perform_async(post.id)')
    end

    it 'renders response operations with status code' do
      md = doc.to_markdown
      expect(md).to include('response')
      expect(md).to include('201')
      expect(md).to include('render_created')
    end

    it 'renders transaction operations with nested rows' do
      md = doc.to_markdown
      expect(md).to include('transaction')
      expect(md).to include('Post.transaction')
      expect(md).to include('Post.create!')
    end

    it 'renders without route when route is nil' do
      doc = described_class.new(entry_point: 'SomeService#call', steps: [])
      md = doc.to_markdown
      expect(md).to include('## SomeService#call')
      expect(md).not_to include('→')
    end

    it 'renders conditional operations' do
      steps_with_cond = [{
        unit: 'Foo',
        type: 'service',
        operations: [{
          type: :conditional,
          kind: 'if',
          condition: 'user.active?',
          line: 5,
          then_ops: [{ type: :call, target: 'User', method: 'activate', line: 6 }],
          else_ops: [{ type: :call, target: 'User', method: 'deactivate', line: 8 }]
        }]
      }]
      doc = described_class.new(entry_point: 'Foo', steps: steps_with_cond)
      md = doc.to_markdown
      expect(md).to include('if user.active?')
      expect(md).to include('User.activate')
      expect(md).to include('User.deactivate')
    end
  end
end
