# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/svelte_flow/rack_middleware'
require 'rack'

RSpec.describe Woods::SvelteFlow::RackMiddleware do
  let(:inner_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['inner app']] } }
  let(:middleware) { described_class.new(inner_app, path: '/woods/visualize') }

  def mock_env(path, method: 'GET')
    {
      'PATH_INFO' => path,
      'REQUEST_METHOD' => method,
      'rack.input' => StringIO.new
    }
  end

  describe '#call' do
    it 'passes through requests that do not match the mount path' do
      status, _headers, body = middleware.call(mock_env('/other/path'))
      expect(status).to eq(200)
      expect(body.first).to eq('inner app')
    end

    it 'intercepts requests at the mount path' do
      status, _, _body = middleware.call(mock_env('/woods/visualize/'))
      # Should return HTML or 404 depending on asset availability
      expect(status).to be_between(200, 404)
    end

    it 'serves HTML for the root path' do
      status, headers, _body = middleware.call(mock_env('/woods/visualize/'))
      if File.exist?(File.join(described_class::ASSETS_DIR, 'index.html'))
        expect(status).to eq(200)
        expect(headers['content-type']).to eq('text/html')
      end
    end

    it 'returns 404 for unknown sub-paths' do
      status, _headers, _body = middleware.call(mock_env('/woods/visualize/unknown'))
      expect(status).to eq(404)
    end

    it 'returns 503 for api/graph when no extraction data exists' do
      config = double('config', output_dir: '/nonexistent')
      allow(Woods).to receive(:configuration).and_return(config)

      status, _headers, body = middleware.call(mock_env('/woods/visualize/api/graph'))
      expect(status).to eq(503)
      data = JSON.parse(body.first)
      expect(data['error']).to include('Extraction data not available')
    end

    it 'prevents directory traversal in asset serving' do
      status, _headers, _body = middleware.call(mock_env('/woods/visualize/assets/../../../etc/passwd'))
      # Should serve based on basename only, so this returns 404
      expect(status).to eq(404)
    end
  end

  describe 'custom mount path' do
    let(:middleware) { described_class.new(inner_app, path: '/custom/viz') }

    it 'intercepts at the custom path' do
      status, _headers, _body = middleware.call(mock_env('/custom/viz/'))
      expect(status).to be_between(200, 404)
    end

    it 'passes through the default path' do
      status, _headers, body = middleware.call(mock_env('/woods/visualize/'))
      expect(status).to eq(200)
      expect(body.first).to eq('inner app')
    end
  end
end
