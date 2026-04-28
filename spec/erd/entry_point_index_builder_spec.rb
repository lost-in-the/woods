# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods/erd/entry_point_index_builder'

RSpec.describe Woods::Erd::EntryPointIndexBuilder do
  let(:output_dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(output_dir) }

  # Writes a route unit in the format produced by the route extractor.
  # Uses http_method (not verb) and a controller dependency edge, matching
  # actual extraction output. Pass legacy_verb: true to test the verb fallback.
  def write_route(verb:, path:, controller:, action:, id: "#{verb}_#{path}", legacy_verb: false)
    routes_dir = File.join(output_dir, 'routes')
    FileUtils.mkdir_p(routes_dir)
    meta_key = legacy_verb ? 'verb' : 'http_method'
    unit = {
      'type' => 'route',
      'identifier' => id,
      'metadata' => { meta_key => verb, 'path' => path, 'action' => action },
      'dependencies' => [{ 'type' => 'controller', 'target' => controller, 'via' => 'route_dispatch' }]
    }
    File.write(File.join(routes_dir, "#{id.gsub(/[^a-z0-9]/i, '_')}.json"), JSON.generate(unit))
  end

  def write_controller(identifier)
    controllers_dir = File.join(output_dir, 'controllers')
    FileUtils.mkdir_p(controllers_dir)
    unit = { 'type' => 'controller', 'identifier' => identifier, 'metadata' => {} }
    File.write(File.join(controllers_dir, "#{identifier.gsub('::', '__')}.json"), JSON.generate(unit))
  end

  it 'includes GET routes whose controller is extracted' do
    write_route(verb: 'GET', path: '/checkout', controller: 'CheckoutController', action: 'new')
    write_controller('CheckoutController')

    result = described_class.new(output_dir).build

    expect(result).to eq([
                           { 'identifier' => 'CheckoutController', 'verb' => 'GET', 'path' => '/checkout',
                             'action' => 'new' }
                         ])
  end

  it 'excludes non-GET routes' do
    write_route(verb: 'POST', path: '/checkout', controller: 'CheckoutController', action: 'create')
    write_controller('CheckoutController')

    expect(described_class.new(output_dir).build).to be_empty
  end

  it 'excludes routes whose controller is not extracted' do
    write_route(verb: 'GET', path: '/orphan', controller: 'UnknownController', action: 'index')

    expect(described_class.new(output_dir).build).to be_empty
  end

  it 'preserves namespaced controller identifiers' do
    write_route(verb: 'GET', path: '/admin/users', controller: 'Admin::UsersController', action: 'index')
    write_controller('Admin::UsersController')

    result = described_class.new(output_dir).build

    expect(result.first['identifier']).to eq('Admin::UsersController')
  end

  it 'sorts entries by path ascending' do
    write_controller('CartController')
    write_controller('CheckoutController')
    write_route(verb: 'GET', path: '/checkout', controller: 'CheckoutController', action: 'new', id: 'r2')
    write_route(verb: 'GET', path: '/cart',     controller: 'CartController',     action: 'show', id: 'r1')

    paths = described_class.new(output_dir).build.map { |e| e['path'] }

    expect(paths).to eq(['/cart', '/checkout'])
  end

  it 'returns [] when routes directory is missing' do
    expect(described_class.new(output_dir).build).to eq([])
  end

  it 'accepts legacy verb key as fallback for http_method' do
    write_route(verb: 'GET', path: '/checkout', controller: 'CheckoutController', action: 'new', legacy_verb: true)
    write_controller('CheckoutController')

    result = described_class.new(output_dir).build

    expect(result.first['verb']).to eq('GET')
  end

  it 'resolves controller identifier from dependency edge, not metadata controller key' do
    routes_dir = File.join(output_dir, 'routes')
    FileUtils.mkdir_p(routes_dir)
    # Simulate real extractor output: metadata has short name, dependency has full class name
    unit = {
      'type' => 'route',
      'identifier' => 'GET_/orders',
      'metadata' => { 'http_method' => 'GET', 'path' => '/orders', 'controller' => 'orders', 'action' => 'index' },
      'dependencies' => [{ 'type' => 'controller', 'target' => 'OrdersController', 'via' => 'route_dispatch' }]
    }
    File.write(File.join(routes_dir, 'GET__orders.json'), JSON.generate(unit))
    write_controller('OrdersController')

    result = described_class.new(output_dir).build

    expect(result.first['identifier']).to eq('OrdersController')
  end
end
