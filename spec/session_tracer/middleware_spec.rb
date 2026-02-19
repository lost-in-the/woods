# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/session_tracer/middleware'
require 'codebase_index/session_tracer/store'

RSpec.describe CodebaseIndex::SessionTracer::Middleware do
  let(:store) { instance_double(CodebaseIndex::SessionTracer::Store) }
  let(:inner_app) { ->(_env) { [200, { 'Content-Type' => 'text/html' }, ['OK']] } }
  let(:middleware) { described_class.new(inner_app, store: store, exclude_paths: ['/assets', '/health']) }

  let(:base_env) do
    {
      'REQUEST_METHOD' => 'GET',
      'PATH_INFO' => '/orders',
      'HTTP_ACCEPT' => 'text/html',
      'action_dispatch.request.path_parameters' => { controller: 'orders', action: 'index' },
      'rack.session' => double(id: 'rack-session-123')
    }
  end

  before do
    allow(store).to receive(:record)
  end

  describe '#call' do
    it 'passes the request through to the inner app' do
      status, headers, body = middleware.call(base_env)

      expect(status).to eq(200)
      expect(headers['Content-Type']).to eq('text/html')
      expect(body).to eq(['OK'])
    end

    it 'records request metadata to the store' do
      middleware.call(base_env)

      expect(store).to have_received(:record).with(
        'rack-session-123',
        hash_including(
          'controller' => 'OrdersController',
          'action' => 'index',
          'method' => 'GET',
          'path' => '/orders',
          'status' => 200
        )
      )
    end

    it 'includes duration_ms in recorded data' do
      middleware.call(base_env)

      expect(store).to have_received(:record).with(
        anything,
        hash_including('duration_ms' => a_kind_of(Integer))
      )
    end

    it 'includes timestamp in recorded data' do
      middleware.call(base_env)

      expect(store).to have_received(:record).with(
        anything,
        hash_including('timestamp' => a_string_matching(/\d{4}-\d{2}-\d{2}T/))
      )
    end
  end

  describe 'session ID extraction' do
    it 'prefers X-Trace-Session header' do
      env = base_env.merge('HTTP_X_TRACE_SESSION' => 'checkout-flow')
      middleware.call(env)

      expect(store).to have_received(:record).with('checkout-flow', anything)
    end

    it 'falls back to rack session ID' do
      middleware.call(base_env)

      expect(store).to have_received(:record).with('rack-session-123', anything)
    end

    it 'uses custom session_id_proc when provided' do
      custom_proc = ->(_env) { 'custom-id-456' }
      mw = described_class.new(inner_app, store: store, session_id_proc: custom_proc)

      mw.call(base_env)

      expect(store).to have_received(:record).with('custom-id-456', anything)
    end

    it 'skips recording when no session ID is available' do
      env = base_env.merge('rack.session' => double(id: nil, dig: nil))
      env.delete('HTTP_X_TRACE_SESSION')

      middleware.call(env)

      expect(store).not_to have_received(:record)
    end
  end

  describe 'path exclusion' do
    it 'skips excluded paths' do
      env = base_env.merge(
        'PATH_INFO' => '/assets/application.js',
        'action_dispatch.request.path_parameters' => { controller: 'assets', action: 'show' }
      )

      middleware.call(env)

      expect(store).not_to have_received(:record)
    end

    it 'skips health check paths' do
      env = base_env.merge(
        'PATH_INFO' => '/health',
        'action_dispatch.request.path_parameters' => { controller: 'health', action: 'show' }
      )

      middleware.call(env)

      expect(store).not_to have_received(:record)
    end

    it 'records non-excluded paths' do
      middleware.call(base_env)

      expect(store).to have_received(:record)
    end
  end

  describe 'controller classification' do
    it 'classifies simple controller names' do
      middleware.call(base_env)

      expect(store).to have_received(:record).with(
        anything,
        hash_including('controller' => 'OrdersController')
      )
    end

    it 'classifies namespaced controller names' do
      env = base_env.merge(
        'action_dispatch.request.path_parameters' => { controller: 'admin/orders', action: 'index' }
      )

      middleware.call(env)

      expect(store).to have_received(:record).with(
        anything,
        hash_including('controller' => 'Admin::OrdersController')
      )
    end
  end

  describe 'error resilience' do
    it 'does not break the request when store raises' do
      allow(store).to receive(:record).and_raise(StandardError, 'store error')

      status, = middleware.call(base_env)

      expect(status).to eq(200)
    end

    it 'does not break when path_parameters are missing' do
      env = base_env.merge('action_dispatch.request.path_parameters' => nil)

      status, = middleware.call(env)

      expect(status).to eq(200)
      expect(store).not_to have_received(:record)
    end

    it 'does not break when controller is missing from path_parameters' do
      env = base_env.merge('action_dispatch.request.path_parameters' => { action: 'index' })

      status, = middleware.call(env)

      expect(status).to eq(200)
      expect(store).not_to have_received(:record)
    end
  end

  describe 'trace_tag' do
    it 'includes trace_tag from X-Trace-Session header' do
      env = base_env.merge('HTTP_X_TRACE_SESSION' => 'checkout-flow')

      middleware.call(env)

      expect(store).to have_received(:record).with(
        anything,
        hash_including('trace_tag' => 'checkout-flow')
      )
    end

    it 'sets trace_tag to nil when header is absent' do
      middleware.call(base_env)

      expect(store).to have_received(:record).with(
        anything,
        hash_including('trace_tag' => nil)
      )
    end
  end

  describe 'format extraction' do
    it 'uses format from path_parameters when present' do
      env = base_env.merge(
        'action_dispatch.request.path_parameters' => { controller: 'orders', action: 'index', format: 'json' }
      )

      middleware.call(env)

      expect(store).to have_received(:record).with(
        anything,
        hash_including('format' => 'json')
      )
    end

    it 'infers json from Accept header' do
      env = base_env.merge('HTTP_ACCEPT' => 'application/json')

      middleware.call(env)

      expect(store).to have_received(:record).with(
        anything,
        hash_including('format' => 'json')
      )
    end

    it 'defaults to html' do
      env = base_env.merge('HTTP_ACCEPT' => '')

      middleware.call(env)

      expect(store).to have_received(:record).with(
        anything,
        hash_including('format' => 'html')
      )
    end
  end
end
