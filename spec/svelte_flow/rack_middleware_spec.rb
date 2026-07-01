# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/svelte_flow/rack_middleware'
require 'rack'
require 'tmpdir'
require 'fileutils'

RSpec.describe Woods::SvelteFlow::RackMiddleware do
  let(:inner_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['inner app']] } }
  let(:middleware) { described_class.new(inner_app, path: '/woods/visualize') }

  def mock_env(url, method: 'GET')
    path, query = url.split('?', 2)
    {
      'PATH_INFO' => path,
      'QUERY_STRING' => query || '',
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

    it 'injects the mount path into served HTML' do
      status, _headers, body = middleware.call(mock_env('/woods/visualize/'))
      next unless status == 200

      html = body.first
      expect(html).to include('content="/woods/visualize"')
      expect(html).not_to include('{{BASE_PATH}}')
    end
  end

  describe 'GET /api/graph/neighbors' do
    context 'when node parameter is missing' do
      it 'returns 400 Bad Request' do
        env = mock_env('/woods/visualize/api/graph/neighbors')
        status, _headers, _body = middleware.call(env)
        expect(status).to eq(400)
      end
    end

    context 'when node is not found in graph' do
      let(:fixture_dir) { Dir.mktmpdir }
      let(:graph_data) do
        {
          'nodes' => { 'Account' => { 'type' => 'model' } },
          'edges' => {},
          'reverse' => {},
          'pagerank' => { 'Account' => 0.016 }
        }
      end

      before do
        File.write(File.join(fixture_dir, 'manifest.json'), JSON.generate({ 'version' => 1 }))
        File.write(File.join(fixture_dir, 'dependency_graph.json'), JSON.generate(graph_data))

        config = double('config', output_dir: fixture_dir)
        allow(Woods).to receive(:configuration).and_return(config)
      end

      after { FileUtils.rm_rf(fixture_dir) }

      it 'returns 404 Not Found' do
        env = mock_env('/woods/visualize/api/graph/neighbors?node=NonExistent&depth=1')
        status, _headers, _body = middleware.call(env)
        expect(status).to eq(404)
      end
    end

    context 'when node exists' do
      let(:fixture_dir) { Dir.mktmpdir }
      let(:graph_data) do
        {
          'nodes' => { 'Account' => { 'type' => 'model' }, 'Order' => { 'type' => 'model' } },
          'edges' => { 'Account' => ['Order'] },
          'reverse' => { 'Order' => ['Account'] },
          'pagerank' => { 'Account' => 0.016, 'Order' => 0.012 }
        }
      end

      before do
        File.write(File.join(fixture_dir, 'manifest.json'), JSON.generate({ 'version' => 1 }))
        File.write(File.join(fixture_dir, 'dependency_graph.json'), JSON.generate(graph_data))

        config = double('config', output_dir: fixture_dir)
        allow(Woods).to receive(:configuration).and_return(config)
      end

      after { FileUtils.rm_rf(fixture_dir) }

      it 'returns the node and its neighbors at depth 1' do
        env = mock_env('/woods/visualize/api/graph/neighbors?node=Account&depth=1')
        status, headers, body = middleware.call(env)
        expect(status).to eq(200)
        expect(headers['content-type']).to eq('application/json')

        data = JSON.parse(body.first)
        expect(data).to have_key('nodes')
        expect(data).to have_key('edges')
        expect(data['nodes']).to be_an(Array)
        node_ids = data['nodes'].map { |n| n['id'] }
        expect(node_ids).to include('Account')
      end

      it 'defaults depth to 1 when not specified' do
        env = mock_env('/woods/visualize/api/graph/neighbors?node=Account')
        status, _headers, body = middleware.call(env)
        expect(status).to eq(200)
        data = JSON.parse(body.first)
        expect(data['nodes']).to be_an(Array)
      end

      it 'includes highest_pagerank in response' do
        env = mock_env('/woods/visualize/api/graph/neighbors?node=Account&depth=1')
        _status, _headers, body = middleware.call(env)
        data = JSON.parse(body.first)
        expect(data).to have_key('highest_pagerank')
      end
    end
  end

  describe 'GET /api/subgraph' do
    let(:fixture_dir) { Dir.mktmpdir }
    let(:graph_data) do
      {
        'nodes' => {
          'Account' => { 'type' => 'model' },
          'Order' => { 'type' => 'model' },
          'Invoice' => { 'type' => 'model' },
          'OrdersController' => { 'type' => 'controller' }
        },
        'edges' => {
          'Order' => [
            { 'target' => 'Account', 'via' => 'belongs_to' },
            { 'target' => 'Invoice', 'via' => 'code_reference' }
          ],
          'OrdersController' => [{ 'target' => 'Order', 'via' => 'code_reference' }]
        },
        'reverse' => {
          'Account' => ['Order'], 'Invoice' => ['Order'], 'Order' => ['OrdersController']
        },
        'pagerank' => { 'Account' => 0.02, 'Order' => 0.03, 'Invoice' => 0.01, 'OrdersController' => 0.02 }
      }
    end

    before do
      File.write(File.join(fixture_dir, 'manifest.json'), JSON.generate({ 'version' => 1 }))
      File.write(File.join(fixture_dir, 'dependency_graph.json'), JSON.generate(graph_data))
      config = double('config', output_dir: fixture_dir)
      allow(Woods).to receive(:configuration).and_return(config)
    end

    after { FileUtils.rm_rf(fixture_dir) }

    def get_subgraph(query)
      _status, _headers, body = middleware.call(mock_env("/woods/visualize/api/subgraph?#{query}"))
      JSON.parse(body.first)
    end

    def node_ids(query)
      get_subgraph(query)['nodes'].map { |n| n['id'] }
    end

    it 'returns 400 when the nodes parameter is missing' do
      status, = middleware.call(mock_env('/woods/visualize/api/subgraph'))
      expect(status).to eq(400)
    end

    it 'returns 404 with the dropped list when no requested node exists' do
      status, _headers, body = middleware.call(mock_env('/woods/visualize/api/subgraph?nodes=Ghost,Phantom'))
      expect(status).to eq(404)
      expect(JSON.parse(body.first)['dropped']).to contain_exactly('Ghost', 'Phantom')
    end

    it 'renders exactly the requested set at depth 0 (induced subgraph)' do
      data = get_subgraph('nodes=Order,Account')
      expect(data['nodes'].map { |n| n['id'] }).to contain_exactly('Order', 'Account')
      expect(data['requested']).to contain_exactly('Order', 'Account')
      expect(data['dropped']).to be_empty
    end

    it 'includes the edge between two requested nodes at depth 0' do
      edges = get_subgraph('nodes=Order,Account')['edges']
      pair = edges.map { |e| [e['source'], e['target']] }
      expect(pair).to include(%w[Order Account])
    end

    it 'pulls in forward and reverse neighbors at depth 1' do
      expect(node_ids('nodes=Order&depth=1'))
        .to contain_exactly('Order', 'Account', 'Invoice', 'OrdersController')
    end

    it 'restricts expansion to the via relationship when filtered' do
      ids = node_ids('nodes=Order&depth=1&via=belongs_to')
      expect(ids).to include('Order', 'Account')
      expect(ids).not_to include('Invoice', 'OrdersController')
    end

    it 'reports unknown identifiers in dropped while rendering the known ones' do
      data = get_subgraph('nodes=Order,Ghost')
      expect(data['requested']).to contain_exactly('Order')
      expect(data['dropped']).to contain_exactly('Ghost')
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
