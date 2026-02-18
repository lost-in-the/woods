# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'codebase_index/extractors/route_extractor'

RSpec.describe CodebaseIndex::Extractors::RouteExtractor do
  let(:logger) { double('Logger', error: nil, warn: nil, debug: nil, info: nil) }

  # Build a mock route object
  def build_route(verb:, path:, controller:, action:, name: nil, constraints: {})
    path_spec = double('PathSpec', to_s: "#{path}(.:format)", spec: double(to_s: "#{path}(.:format)"))
    double('Route',
           verb: verb,
           path: path_spec,
           defaults: { controller: controller, action: action },
           name: name,
           constraints: constraints)
  end

  # ── No routes available ──────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing Rails routes gracefully' do
      stub_const('Rails', double('Rails', logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(false)

      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    let(:routes) do
      [
        build_route(verb: 'GET', path: '/users', controller: 'users', action: 'index', name: 'users'),
        build_route(verb: 'POST', path: '/users', controller: 'users', action: 'create'),
        build_route(verb: 'GET', path: '/users/:id', controller: 'users', action: 'show', name: 'user')
      ]
    end

    before do
      routes_collection = double('RoutesCollection', routes: routes)
      application = double('Application', routes: routes_collection)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)
    end

    it 'extracts all routes' do
      units = described_class.new.extract_all
      expect(units.size).to eq(3)
    end

    it 'creates route units with correct identifiers' do
      units = described_class.new.extract_all
      identifiers = units.map(&:identifier)

      expect(identifiers).to include('GET /users')
      expect(identifiers).to include('POST /users')
      expect(identifiers).to include('GET /users/:id')
    end

    it 'sets type to :route' do
      units = described_class.new.extract_all
      expect(units.map(&:type)).to all(eq(:route))
    end
  end

  # ── Route metadata ──────────────────────────────────────────────────

  describe 'route metadata' do
    let(:route) do
      build_route(
        verb: 'POST',
        path: '/api/v1/orders/:id/refund',
        controller: 'api/v1/orders',
        action: 'refund',
        name: 'api_v1_order_refund',
        constraints: { id: /\d+/ }
      )
    end

    before do
      routes_collection = double('RoutesCollection', routes: [route])
      application = double('Application', routes: routes_collection)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)
    end

    it 'extracts HTTP method' do
      unit = described_class.new.extract_all.first
      expect(unit.metadata[:http_method]).to eq('POST')
    end

    it 'extracts path' do
      unit = described_class.new.extract_all.first
      expect(unit.metadata[:path]).to eq('/api/v1/orders/:id/refund')
    end

    it 'extracts controller and action' do
      unit = described_class.new.extract_all.first
      expect(unit.metadata[:controller]).to eq('api/v1/orders')
      expect(unit.metadata[:action]).to eq('refund')
    end

    it 'extracts route name' do
      unit = described_class.new.extract_all.first
      expect(unit.metadata[:route_name]).to eq('api_v1_order_refund')
    end

    it 'extracts path params' do
      unit = described_class.new.extract_all.first
      expect(unit.metadata[:path_params]).to include('id')
    end

    it 'extracts constraints' do
      unit = described_class.new.extract_all.first
      expect(unit.metadata[:constraints]).to eq({ id: /\d+/ })
    end
  end

  # ── Namespacing ─────────────────────────────────────────────────────

  describe 'namespace extraction' do
    let(:route) do
      build_route(
        verb: 'GET',
        path: '/admin/users',
        controller: 'admin/users',
        action: 'index'
      )
    end

    before do
      routes_collection = double('RoutesCollection', routes: [route])
      application = double('Application', routes: routes_collection)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)
    end

    it 'extracts namespace from controller path' do
      unit = described_class.new.extract_all.first
      expect(unit.namespace).to eq('Admin')
    end
  end

  # ── Source code ─────────────────────────────────────────────────────

  describe 'source code' do
    let(:route) do
      build_route(
        verb: 'GET',
        path: '/users',
        controller: 'users',
        action: 'index',
        name: 'users'
      )
    end

    before do
      routes_collection = double('RoutesCollection', routes: [route])
      application = double('Application', routes: routes_collection)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)
    end

    it 'builds readable source representation' do
      unit = described_class.new.extract_all.first
      expect(unit.source_code).to include('Route: GET /users')
      expect(unit.source_code).to include('Controller: users#index')
      expect(unit.source_code).to include("get '/users', to: 'users#index'")
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependency extraction' do
    let(:route) do
      build_route(
        verb: 'GET',
        path: '/users',
        controller: 'users',
        action: 'index'
      )
    end

    before do
      routes_collection = double('RoutesCollection', routes: [route])
      application = double('Application', routes: routes_collection)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)
    end

    it 'links to controller as dependency' do
      unit = described_class.new.extract_all.first
      controller_deps = unit.dependencies.select { |d| d[:type] == :controller }
      expect(controller_deps.first[:target]).to eq('UsersController')
      expect(controller_deps.first[:via]).to eq(:route_dispatch)
    end

    it 'all dependencies have :via key' do
      unit = described_class.new.extract_all.first
      unit.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end
  end

  # ── Edge cases ──────────────────────────────────────────────────────

  describe 'edge cases' do
    it 'skips routes without controller/action' do
      incomplete_route = double('Route',
                                verb: 'GET',
                                path: double(to_s: '/(.:format)', spec: double(to_s: '/(.:format)')),
                                defaults: {},
                                name: nil,
                                constraints: {})

      routes_collection = double('RoutesCollection', routes: [incomplete_route])
      application = double('Application', routes: routes_collection)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)

      units = described_class.new.extract_all
      expect(units).to be_empty
    end

    it 'handles routes with non-string verb' do
      route = double('Route',
                     verb: /^GET$/,
                     path: double(to_s: '/test(.:format)', spec: double(to_s: '/test(.:format)')),
                     defaults: { controller: 'tests', action: 'index' },
                     name: nil,
                     constraints: {})

      routes_collection = double('RoutesCollection', routes: [route])
      application = double('Application', routes: routes_collection)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.metadata[:http_method]).to eq('GET')
    end
  end
end
