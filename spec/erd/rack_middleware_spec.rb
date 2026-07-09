# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'woods/erd/rack_middleware'
require 'rack'

RSpec.describe Woods::Erd::RackMiddleware do
  let(:inner_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['inner app']] } }
  let(:output_dir) { Dir.mktmpdir }
  let(:assets_dir) { Dir.mktmpdir }
  let(:middleware) do
    described_class.new(inner_app, path: '/woods/erd', output_dir: output_dir, assets_dir: assets_dir)
  end

  after do
    FileUtils.remove_entry(output_dir)
    FileUtils.remove_entry(assets_dir)
  end

  def request(path, method: 'GET')
    env = Rack::MockRequest.env_for(path, method: method)
    middleware.call(env)
  end

  describe 'pass-through' do
    it 'passes non-matching requests to the inner app' do
      status, _headers, body = request('/other/path')

      expect(status).to eq(200)
      expect(body).to eq(['inner app'])
    end
  end

  describe 'index.html serving' do
    before do
      File.write(File.join(assets_dir, 'index.html'), '<html>ERD</html>')
    end

    it 'redirects base path to trailing slash' do
      status, headers, _body = request('/woods/erd')

      expect(status).to eq(301)
      expect(headers['location']).to eq('/woods/erd/')
    end

    it 'serves index.html at the base path with trailing slash' do
      status, headers, _body = request('/woods/erd/')

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('text/html')
    end
  end

  describe 'static asset serving' do
    before do
      FileUtils.mkdir_p(File.join(assets_dir, 'assets'))
      File.write(File.join(assets_dir, 'assets', 'main.js'), 'console.log("erd")')
      File.write(File.join(assets_dir, 'assets', 'style.css'), 'body {}')
    end

    it 'serves JavaScript files with correct content type' do
      status, headers, body = request('/woods/erd/assets/main.js')

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('application/javascript')
      expect(body.join).to include('console.log')
    end

    it 'serves CSS files with correct content type' do
      status, headers, _body = request('/woods/erd/assets/style.css')

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('text/css')
    end

    it 'returns 404 for missing assets' do
      status, _headers, _body = request('/woods/erd/assets/missing.js')

      expect(status).to eq(404)
    end
  end

  describe 'schema.json serving' do
    before do
      models_dir = File.join(output_dir, 'models')
      FileUtils.mkdir_p(models_dir)

      unit = {
        'type' => 'model',
        'identifier' => 'Post',
        'metadata' => {
          'table_name' => 'posts',
          'table_exists' => true,
          'primary_key' => 'id',
          'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil }],
          'associations' => [],
          'indexes' => [],
          'foreign_keys' => [],
          'enums' => {}
        }
      }

      digest = Digest::SHA256.hexdigest('Post')[0, 8]
      File.write(File.join(models_dir, "Post_#{digest}.json"), JSON.generate(unit))
      File.write(File.join(models_dir, '_index.json'),
                 JSON.generate([{ 'identifier' => 'Post', 'file' => "Post_#{digest}.json" }]))
    end

    it 'serves generated schema.json' do
      status, headers, body = request('/woods/erd/schema.json')

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('application/json')

      schema = JSON.parse(body.join)
      expect(schema['tables']).to have_key('posts')
    end

    it 'caches schema.json after first request' do
      request('/woods/erd/schema.json')

      # Delete the source files — cached response should still work
      FileUtils.rm_rf(File.join(output_dir, 'models'))

      status, _headers, body = request('/woods/erd/schema.json')

      expect(status).to eq(200)
      schema = JSON.parse(body.join)
      expect(schema['tables']).to have_key('posts')
    end
  end

  describe 'error handling' do
    it 'returns error JSON when no extraction data exists' do
      status, headers, body = request('/woods/erd/schema.json')

      expect(status).to eq(503)
      expect(headers['content-type']).to eq('application/json')

      error = JSON.parse(body.join)
      expect(error['error']).to match(/extract/i)
    end
  end

  describe 'path traversal protection' do
    before do
      File.write(File.join(assets_dir, 'index.html'), '<html>ERD</html>')
    end

    it 'rejects path traversal attempts' do
      status, _headers, _body = request('/woods/erd/../../../etc/passwd')

      expect(status).to eq(404)
    end
  end
end
