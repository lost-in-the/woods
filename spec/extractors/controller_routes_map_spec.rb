# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/controller_extractor'

# The routes map groups the route table once and renders a controller's
# route info only when that controller is asked for.
RSpec.describe Woods::Extractors::ControllerExtractor, 'routes map' do
  def route(controller, action, path, verb: 'GET', name: nil)
    spec = double("spec #{path}")
    allow(spec).to receive(:to_s).and_return("#{path}(.:format)")
    double("route #{path}", defaults: { controller: controller, action: action }.compact,
                            path: double(spec: spec), verb: verb, name: name,
                            constraints: { request_method: /GET/, subdomain: 'api' })
  end

  let(:posts_show) { route('posts', 'show', '/posts/:id', name: 'post') }
  let(:posts_index) { route('posts', 'index', '/posts', name: 'posts') }
  let(:posts_legacy) { route('posts', 'index', '/articles') }
  let(:admin_users) { route('admin/users', 'index', '/admin/users') }
  let(:mounted) { route(nil, nil, '/engine') }
  let(:table) { [posts_show, posts_index, mounted, admin_users, posts_legacy] }

  let(:map) do
    stub_const('Rails', double('Rails', application: double(routes: double(routes: table)),
                                        root: Pathname.new('/app')))
    described_class.new.send(:routes_map)
  end

  it 'answers a controller with key-sorted actions and routes in table order' do
    expect(map['PostsController']).to eq(
      'index' => [
        { verb: 'GET', path: '/posts', name: 'posts', constraints: { subdomain: 'api' } },
        { verb: 'GET', path: '/articles', name: nil, constraints: { subdomain: 'api' } }
      ],
      'show' => [{ verb: 'GET', path: '/posts/:id', name: 'post', constraints: { subdomain: 'api' } }]
    )
  end

  it 'names a namespaced controller by its constant' do
    expect(map.dig('Admin::UsersController', 'index').map { |info| info[:path] }).to eq(['/admin/users'])
  end

  it 'answers nil for a controller with no route, and for a route with no controller' do
    expect(map['CommentsController']).to be_nil
    expect(map.dig('CommentsController', 'index')).to be_nil
    expect(map.keys).to be_empty
  end

  it 'renders only the routes of the controller asked for' do
    map['Admin::UsersController']

    expect(admin_users.path.spec).to have_received(:to_s).once
    expect(posts_show.path.spec).not_to have_received(:to_s)
    expect(posts_index.path.spec).not_to have_received(:to_s)
  end

  it 'renders a controller once however often it is read' do
    3.times { map['PostsController'] }

    expect(posts_show.path.spec).to have_received(:to_s).once
  end
end
