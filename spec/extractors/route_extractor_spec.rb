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

  describe 'route source locations' do
    let(:root) { Dir.mktmpdir }

    after { FileUtils.rm_rf(root) }

    def write_routes(relative, source)
      path = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
      path
    end

    def located_route(location, **attributes)
      route = build_route(**attributes)
      allow(route).to receive(:source_location).and_return(location)
      route
    end

    def stub_rooted_routes(routes)
      application = double('Application', routes: double('RoutesCollection', routes: routes))
      stub_const('Rails', double('Rails', application: application, logger: logger, root: Pathname.new(root)))
    end

    def routes_of(units)
      units.select { |unit| unit.type == :route }
    end

    def route_files_of(units)
      units.select { |unit| unit.type == :route_file }
    end

    it 'records the draw file and line a route was drawn at' do
      path = write_routes('config/routes/admin.rb', "resources :widgets\n")
      write_routes('config/routes.rb', "Rails.application.routes.draw do\n  draw(:admin)\nend\n")
      stub_rooted_routes([located_route('config/routes/admin.rb:1', verb: 'GET', path: '/widgets',
                                                                    controller: 'widgets', action: 'index')])

      route = routes_of(described_class.new.extract_all).first

      expect(route.file_path).to eq(path)
      expect(route.metadata[:line_number]).to eq(1)
      expect(route.source_code).to include('# Source: config/routes/admin.rb:1')
      expect(route.dependencies).to include(type: :route_file, target: 'config/routes/admin.rb', via: :drawn_in)
    end

    it 'accepts an absolute location under the application root' do
      path = write_routes('config/routes.rb', "get '/widgets', to: 'widgets#index'\n")
      stub_rooted_routes([located_route("#{path}:1", verb: 'GET', path: '/widgets',
                                                     controller: 'widgets', action: 'index')])

      expect(routes_of(described_class.new.extract_all).first.file_path).to eq(path)
    end

    it 'leaves the path empty when the runtime exposes no location' do
      write_routes('config/routes.rb', "get '/widgets', to: 'widgets#index'\n")
      stub_rooted_routes([build_route(verb: 'GET', path: '/widgets', controller: 'widgets', action: 'index'),
                          located_route(nil, verb: 'GET', path: '/ledgers', controller: 'ledgers', action: 'index')])

      routes = routes_of(described_class.new.extract_all)

      expect(routes.map(&:file_path)).to eq([nil, nil])
      expect(routes.map { |route| route.metadata[:line_number] }).to eq([nil, nil])
      expect(routes.flat_map(&:dependencies).map { |edge| edge[:via] }).to eq(%i[route_dispatch route_dispatch])
    end

    it 'ignores a location outside the route files, in a gem, or without a line' do
      write_routes('config/routes.rb', "get '/widgets', to: 'widgets#index'\n")
      write_routes('lib/extra_routes.rb', "get '/extra', to: 'extra#index'\n")
      locations = ['lib/extra_routes.rb:1', 'shipment (1.2.0) lib/shipment/routes.rb:4', 'config/routes.rb',
                   'config/routes/missing.rb:3', '/elsewhere/config/routes.rb:1']
      stub_rooted_routes(locations.each_with_index.map do |location, index|
        located_route(location, verb: 'GET', path: "/w#{index}", controller: 'widgets', action: 'index')
      end)

      expect(routes_of(described_class.new.extract_all).map(&:file_path)).to all(be_nil)
    end

    it 'emits one route_file unit per draw file, with the routes it draws' do
      main = write_routes('config/routes.rb', <<~RUBY)
        Rails.application.routes.draw do
          # get '/commented', to: 'widgets#commented'
          root 'widgets#index'
          draw(:admin)
          draw "api/v1"
          mount Ledger::Engine => '/ledger'
        end
      RUBY
      write_routes('config/routes/admin.rb', "namespace :admin do\n  resources :widgets\nend\n")
      write_routes('config/routes/api/v1.rb', "get '/ping', to: 'pings#show'\n")
      stub_rooted_routes([
                           located_route('config/routes/admin.rb:2', verb: 'GET', path: '/admin/widgets',
                                                                     controller: 'admin/widgets', action: 'index'),
                           located_route('config/routes.rb:3', verb: 'GET', path: '/',
                                                               controller: 'widgets', action: 'index'),
                           located_route('config/routes/admin.rb:2', verb: 'POST', path: '/admin/widgets',
                                                                     controller: 'admin/widgets', action: 'create')
                         ])

      files = route_files_of(described_class.new.extract_all)

      expect(files.map(&:identifier)).to eq(%w[config/routes.rb config/routes/admin.rb config/routes/api/v1.rb])
      root_file, admin, api = files
      expect(root_file.file_path).to eq(main)
      expect(root_file.source_code).to include("root 'widgets#index'")
      expect(root_file.metadata).to include(draws: %w[admin api/v1], source_locations: true, routes: ['GET /'])
      expect(root_file.metadata[:declarations]).to eq(
        [{ line: 3, method: 'root', argument: 'widgets#index' }, { line: 4, method: 'draw', argument: 'admin' },
         { line: 5, method: 'draw', argument: 'api/v1' }, { line: 6, method: 'mount', argument: nil }]
      )
      expect(root_file.dependencies).to eq(
        [{ type: :route_file, target: 'config/routes/admin.rb', via: :draw },
         { type: :route_file, target: 'config/routes/api/v1.rb', via: :draw }]
      )
      expect(admin.metadata[:routes]).to eq(['GET /admin/widgets', 'POST /admin/widgets'])
      expect(admin.metadata[:declarations].map { |entry| entry[:method] }).to eq(%w[namespace resources])
      expect(api.metadata).to include(routes: [], route_count: 0)
    end

    it 'still lists declared routes when the runtime exposes no locations' do
      write_routes('config/routes.rb', "get '/widgets', to: 'widgets#index'\nresources :ledgers\n")
      stub_rooted_routes([build_route(verb: 'GET', path: '/widgets', controller: 'widgets', action: 'index')])

      file = route_files_of(described_class.new.extract_all).first

      expect(file.metadata).to include(source_locations: false, routes: [], route_count: 0)
      expect(file.metadata[:declarations]).to eq(
        [{ line: 1, method: 'get', argument: '/widgets' }, { line: 2, method: 'resources', argument: 'ledgers' }]
      )
    end

    it 'redacts credential-shaped text in a route file and refuses one outside the root' do
      write_routes('config/routes.rb', "mount Ledger::Web => '/ledger', auth: 'https://ledger:plaintext-marker@x.example'\n")
      outside = Dir.mktmpdir
      File.write(File.join(outside, 'admin.rb'), "PLAINTEXT_MARKER = 1\n")
      FileUtils.mkdir_p(File.join(root, 'config/routes'))
      File.symlink(File.join(outside, 'admin.rb'), File.join(root, 'config/routes/admin.rb'))
      stub_rooted_routes([located_route('config/routes/admin.rb:1', verb: 'GET', path: '/widgets',
                                                                    controller: 'widgets', action: 'index')])

      units = described_class.new.extract_all

      expect(route_files_of(units).map(&:identifier)).to eq(%w[config/routes.rb])
      expect(route_files_of(units).first.source_code).not_to include('plaintext-marker')
      expect(routes_of(units).first.file_path).to be_nil
    ensure
      FileUtils.rm_rf(outside)
    end

    it 'emits no route_file unit when the application has no route files' do
      stub_rooted_routes([build_route(verb: 'GET', path: '/widgets', controller: 'widgets', action: 'index')])

      expect(route_files_of(described_class.new.extract_all)).to be_empty
    end
  end
end
