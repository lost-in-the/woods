# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods/erd/entry_point_index_builder'

RSpec.describe Woods::Erd::EntryPointIndexBuilder do
  let(:output_dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(output_dir) }

  def write_route(verb:, path:, controller:, action:, id: "#{verb}_#{path}")
    routes_dir = File.join(output_dir, 'routes')
    FileUtils.mkdir_p(routes_dir)
    unit = {
      'type' => 'route',
      'identifier' => id,
      'metadata' => { 'verb' => verb, 'path' => path, 'controller' => controller, 'action' => action }
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
end
