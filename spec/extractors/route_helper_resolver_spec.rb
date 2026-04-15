# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/route_helper_resolver'

RSpec.describe Woods::Extractors::RouteHelperResolver do
  let(:test_class) do
    Class.new do
      include Woods::Extractors::RouteHelperResolver

      def initialize(named_routes)
        @named_routes = named_routes
        build_route_helper_map
      end
    end
  end

  # Stub Rails route objects
  let(:posts_index_route) do
    double('Route',
           defaults: { controller: 'posts', action: 'index' },
           path: double(spec: double(to_s: '/posts(.:format)')),
           verb: 'GET')
  end

  let(:new_post_route) do
    double('Route',
           defaults: { controller: 'posts', action: 'new' },
           path: double(spec: double(to_s: '/posts/new(.:format)')),
           verb: 'GET')
  end

  let(:create_post_route) do
    double('Route',
           defaults: { controller: 'posts', action: 'create' },
           path: double(spec: double(to_s: '/posts(.:format)')),
           verb: 'POST')
  end

  let(:admin_users_route) do
    double('Route',
           defaults: { controller: 'admin/users', action: 'index' },
           path: double(spec: double(to_s: '/admin/users(.:format)')),
           verb: 'GET')
  end

  let(:named_routes) do
    {
      posts: posts_index_route,
      new_post: new_post_route,
      post: create_post_route,
      admin_users: admin_users_route
    }
  end

  before do
    app = double('Rails.application', routes: double(named_routes: named_routes))
    stub_const('Rails', double(application: app))
  end

  subject { test_class.new(named_routes) }

  describe '#resolve_route_helper' do
    it 'resolves a _path helper to controller and action' do
      result = subject.resolve_route_helper('posts_path')
      expect(result).to eq({
                             controller: 'PostsController',
                             action: 'index',
                             path: '/posts',
                             verb: 'GET'
                           })
    end

    it 'resolves a _url helper to controller and action' do
      result = subject.resolve_route_helper('new_post_url')
      expect(result).to eq({
                             controller: 'PostsController',
                             action: 'new',
                             path: '/posts/new',
                             verb: 'GET'
                           })
    end

    it 'resolves a namespaced controller' do
      result = subject.resolve_route_helper('admin_users_path')
      expect(result).to eq({
                             controller: 'Admin::UsersController',
                             action: 'index',
                             path: '/admin/users',
                             verb: 'GET'
                           })
    end

    it 'returns nil for an unknown route helper' do
      expect(subject.resolve_route_helper('nonexistent_path')).to be_nil
    end

    it 'ignores asset helpers' do
      expect(subject.resolve_route_helper('asset_path')).to be_nil
    end

    it 'ignores image helpers' do
      expect(subject.resolve_route_helper('image_logo_path')).to be_nil
    end

    it 'ignores stylesheet helpers' do
      expect(subject.resolve_route_helper('stylesheet_application_path')).to be_nil
    end

    it 'ignores javascript helpers' do
      expect(subject.resolve_route_helper('javascript_application_path')).to be_nil
    end

    it 'ignores turbo_stream helpers' do
      expect(subject.resolve_route_helper('turbo_stream_path')).to be_nil
    end
  end

  describe '#build_route_helper_map' do
    it 'builds a map from all named routes' do
      resolver = test_class.new(named_routes)
      map = resolver.instance_variable_get(:@route_helper_map)
      expect(map.keys).to contain_exactly('posts', 'new_post', 'post', 'admin_users')
    end

    it 'handles missing Rails gracefully' do
      hide_const('Rails')
      resolver = Class.new { include Woods::Extractors::RouteHelperResolver }.new
      resolver.build_route_helper_map
      expect(resolver.resolve_route_helper('posts_path')).to be_nil
    end
  end
end
