# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'woods/extractors/route_extractor'

RSpec.describe Woods::Extractors::RouteExtractor do
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

  # ── B-127: routes that share a verb and path ─────────────────────────

  describe 'routes differing only by constraint (B-127)' do
    def stub_routes(routes)
      routes_collection = double('RoutesCollection', routes: routes)
      application = double('Application', routes: routes_collection)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)
    end

    it 'folds request constraints into the identifier so both routes survive' do
      stub_routes([
                    build_route(verb: 'GET', path: '/users', controller: 'users', action: 'index'),
                    build_route(verb: 'GET', path: '/users', controller: 'api_users', action: 'index',
                                constraints: { subdomain: 'api' })
                  ])
      ids = described_class.new.extract_all.map(&:identifier)
      expect(ids).to eq(['GET /users', 'GET /users [subdomain=api]'])
    end

    it 'does not qualify a route by a path-segment requirement' do
      stub_routes([build_route(verb: 'GET', path: '/users/:id', controller: 'users', action: 'show',
                               constraints: { id: /\d+/ })])
      expect(described_class.new.extract_all.first.identifier).to eq('GET /users/:id')
    end

    it 'numbers routes that still collide after constraints are applied' do
      stub_routes([
                    build_route(verb: 'GET', path: '/users', controller: 'users', action: 'index'),
                    build_route(verb: 'GET', path: '/users', controller: 'legacy', action: 'index')
                  ])
      ids = described_class.new.extract_all.map(&:identifier)
      expect(ids).to eq(['GET /users', 'GET /users #2'])
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

  # ── Controller-less routes: mounts, redirects, Rack endpoints ────────

  describe 'controller-less routes' do
    # Minimal stand-ins for the ActionDispatch endpoint classes, so the unit
    # suite stays Rails-free. The booted-app spec draws a real RouteSet.
    before do
      redirect = Class.new do
        attr_reader :status, :block

        def initialize(status, block)
          @status = status
          @block = block
        end
      end
      stub_const('ActionDispatch::Routing::Redirect', redirect)
      stub_const('ActionDispatch::Routing::PathRedirect', Class.new(redirect))
      stub_const('ActionDispatch::Routing::OptionRedirect', Class.new(redirect) { alias_method :options, :block })
      stub_const('ActionDispatch::Routing::Mapper::Constraints', Class.new do
        attr_reader :app, :constraints

        def initialize(app, constraints = [])
          @app = app
          @constraints = constraints
        end

        def dispatcher?
          false
        end
      end)
      stub_const('Ledger::Engine', Class.new do
        def self.engine_name = 'ledger'
        def self.routes = []
      end)
      stub_const('ApiFallback', Class.new { def call(_env) = [410, {}, []] })
    end

    def endpoint_route(app:, path:, verb: '', anchored: true, name: nil, constraints: {}, format: true)
      spec = format ? "#{path}(.:format)" : path
      double('Route', verb: verb, path: double('Path', spec: double(to_s: spec), anchored: anchored),
                      defaults: constraints.dup, name: name, constraints: constraints, requirements: {},
                      app: ActionDispatch::Routing::Mapper::Constraints.new(app))
    end

    def stub_routes(routes)
      routes_collection = double('RoutesCollection', routes: routes)
      application = double('Application', routes: routes_collection)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)
    end

    def extract(*routes)
      stub_routes(routes)
      described_class.new.extract_all
    end

    it 'emits a mount unit pointing at the mounted engine, with an edge to its engine unit' do
      unit = extract(endpoint_route(app: Ledger::Engine, path: '/ledger', anchored: false, format: false)).first

      expect(unit.identifier).to eq('ANY /ledger (mount)')
      expect(unit.metadata).to include(kind: 'mount', app: 'Ledger::Engine', path: '/ledger', http_method: 'ANY')
      expect(unit.dependencies).to eq([{ type: :engine, target: 'Ledger::Engine', via: :mount }])
    end

    it 'links no engine unit for a mounted class that is not an engine' do
      stub_const('Docs::App', Class.new { def self.call(_env) = [200, {}, []] })
      unit = extract(endpoint_route(app: Docs::App, path: '/docs', anchored: false, format: false)).first
      expect(unit.metadata).to include(kind: 'mount', app: 'Docs::App')
      expect(unit.dependencies).to eq([])
    end

    it 'emits a mount unit for a mounted Rack server instance, with no edge' do
      server = Class.new { def call(_env) = [200, {}, []] }
      stub_const('Socket::Server', server)
      unit = extract(endpoint_route(app: server.new, path: '/cable', anchored: false, format: false)).first

      expect(unit.identifier).to eq('ANY /cable (mount)')
      expect(unit.metadata).to include(kind: 'mount', app: 'Socket::Server')
      expect(unit.dependencies).to eq([])
    end

    it 'emits a redirect unit carrying a static target and status' do
      redirect = ActionDispatch::Routing::PathRedirect.new(301, '/account/settings')
      unit = extract(endpoint_route(app: redirect, path: '/settings', verb: 'GET', name: 'settings')).first

      expect(unit.identifier).to eq('GET /settings (redirect)')
      expect(unit.metadata).to include(kind: 'redirect', redirect_target: '/account/settings', redirect_status: 301,
                                       app: 'ActionDispatch::Routing::PathRedirect', route_name: 'settings')
      expect(unit.source_code).to include("get '/settings', to: redirect('/account/settings')")
    end

    it 'renders an options redirect target as sorted key=value pairs' do
      redirect = ActionDispatch::Routing::OptionRedirect.new(302, { subdomain: 'app', path: '/home' })
      unit = extract(endpoint_route(app: redirect, path: '/start', verb: 'GET')).first
      expect(unit.metadata).to include(redirect_target: 'path=/home, subdomain=app', redirect_status: 302)
    end

    it 'records a block redirect target as dynamic' do
      redirect = ActionDispatch::Routing::Redirect.new(301, ->(_params, _req) { '/new' })
      unit = extract(endpoint_route(app: redirect, path: '/old', verb: 'GET')).first
      expect(unit.metadata).to include(kind: 'redirect', redirect_target: 'dynamic')
    end

    it 'emits a rack_endpoint unit naming the endpoint class' do
      unit = extract(endpoint_route(app: ApiFallback.new, path: '/v1/*unmatched_route')).first

      expect(unit.identifier).to eq('ANY /v1/*unmatched_route (rack_endpoint)')
      expect(unit.metadata).to include(kind: 'rack_endpoint', app: 'ApiFallback', path_params: [])
      expect(unit.dependencies).to eq([])
    end

    it 'qualifies a constrained root redirect by its constraint before the kind' do
      redirect = ActionDispatch::Routing::PathRedirect.new(301, 'https://www.example.test/')
      unit = extract(endpoint_route(app: redirect, path: '/', verb: 'GET', format: false,
                                    constraints: { subdomain: 'www' })).first
      expect(unit.identifier).to eq('GET / [subdomain=www] (redirect)')
    end

    it 'never emits a route_dispatch edge' do
      redirect = ActionDispatch::Routing::PathRedirect.new(301, '/b')
      units = extract(endpoint_route(app: Ledger::Engine, path: '/ledger', anchored: false, format: false),
                      endpoint_route(app: redirect, path: '/a', verb: 'GET'),
                      endpoint_route(app: ApiFallback.new, path: '/v1/*rest'))
      expect(units.size).to eq(3)
      expect(units.flat_map(&:dependencies).map { |d| d[:via] }).not_to include(:route_dispatch)
    end

    it 'skips a dispatcher endpoint that lacks an action' do
      dispatcher = double('Dispatcher', dispatcher?: true)
      expect(extract(endpoint_route(app: dispatcher, path: '/legacy/:action', verb: 'GET'))).to be_empty
    end

    it 'leaves an existing controller route unrenamed and unchanged beside a redirect on the same path' do
      controller_route = build_route(verb: 'GET', path: '/settings', controller: 'settings', action: 'show',
                                     name: 'settings')
      redirect = endpoint_route(app: ActionDispatch::Routing::PathRedirect.new(301, '/account/settings'),
                                path: '/settings', verb: 'GET')
      units = extract(redirect, controller_route)
      controller_unit = units.find { |u| u.metadata[:controller] }

      expect(units.map(&:identifier)).to eq(['GET /settings (redirect)', 'GET /settings'])
      expect(controller_unit.metadata).to eq(http_method: 'GET', path: '/settings', controller: 'settings',
                                             action: 'show', route_name: 'settings', constraints: {}, path_params: [])
      expect(controller_unit.source_code).to eq(<<~SOURCE.chomp)
        # Route: GET /settings
        # Name: settings
        # Controller: settings#show
        #
        # get '/settings', to: 'settings#show'
      SOURCE
      expect(controller_unit.dependencies).to eq([{ type: :controller, target: 'SettingsController',
                                                    via: :route_dispatch }])
    end
  end

  # ── Edge cases ──────────────────────────────────────────────────────

  describe 'edge cases' do
    it 'skips a route with no controller, action, or endpoint app' do
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
