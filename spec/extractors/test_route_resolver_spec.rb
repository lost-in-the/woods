# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'woods'
require 'woods/extractors/test_route_resolver'

RSpec.describe Woods::Extractors::TestRouteResolver do
  let(:logger) { double('Logger', error: nil, warn: nil, debug: nil, info: nil) }
  let(:routes) do
    [
      route_double(verb: 'GET', path: '/', controller: 'home', action: 'show', name: 'root'),
      route_double(verb: 'GET', path: '/widgets', controller: 'widgets', action: 'index', name: 'widgets'),
      route_double(verb: 'POST', path: '/widgets', controller: 'widgets', action: 'create'),
      route_double(verb: 'GET', path: '/widgets/new', controller: 'widgets', action: 'new', name: 'new_widget'),
      route_double(verb: 'GET', path: '/widgets/:id', controller: 'widgets', action: 'show', name: 'widget'),
      route_double(verb: 'PATCH', path: '/widgets/:id', controller: 'widgets', action: 'update'),
      route_double(verb: 'DELETE', path: '/widgets/:id', controller: 'widgets', action: 'destroy'),
      route_double(verb: 'GET', path: '/ledgers/:ledger_id/entries(/:page)', controller: 'ledger/entries',
                   action: 'index', name: 'ledger_entries'),
      route_double(verb: 'GET', path: '/files/*path', controller: 'files', action: 'show', name: 'file'),
      route_double(verb: 'GET', path: '/api/widgets', controller: 'api/widgets', action: 'index',
                   constraints: { subdomain: 'api' })
    ]
  end

  before { stub_route_set(routes, root: Pathname.new(Dir.tmpdir), logger: logger) }

  def exercised(source)
    described_class.new.exercised(source)
  end

  it 'resolves visit with a route helper' do
    expect(exercised("visit new_widget_path\nvisit widget_url(widget)\n")).to eq(['GET /widgets/:id',
                                                                                  'GET /widgets/new'])
  end

  it 'resolves a request verb with a route helper to the route for that verb' do
    source = "post widgets_path, params: { widget: {} }\ndelete widget_path(widget)\npatch(widget_path(widget))\n"

    expect(exercised(source)).to eq(['DELETE /widgets/:id', 'PATCH /widgets/:id', 'POST /widgets'])
  end

  it 'resolves literal paths in either quote style' do
    expect(exercised(%(visit "/widgets"\nget '/widgets/new'\npost("/widgets")\n)))
      .to eq(['GET /widgets', 'GET /widgets/new', 'POST /widgets'])
  end

  it 'matches a literal against dynamic segments in route order' do
    expect(exercised(%(get "/widgets/42"\nget "/widgets/new"\n))).to eq(['GET /widgets/:id', 'GET /widgets/new'])
  end

  it 'treats an interpolation as one path segment value' do
    source = <<~'RUBY'
      visit "/widgets/#{widget.id}"
      get "/ledgers/#{ledger.id}/entries/#{page}"
    RUBY

    expect(exercised(source)).to eq(['GET /ledgers/:ledger_id/entries(/:page)', 'GET /widgets/:id'])
  end

  it 'ignores the query string, fragment, format, and a trailing slash' do
    source = %(visit "/widgets?page=2"\nvisit "/widgets/7.json"\nvisit "/widgets/new#form"\nvisit "/widgets/"\n)

    expect(exercised(source)).to eq(['GET /widgets', 'GET /widgets/:id', 'GET /widgets/new'])
  end

  it 'resolves the root path and optional and glob segments' do
    expect(exercised(%(visit "/"\nvisit root_path\nget "/ledgers/3/entries"\nget "/files/a/b/c.txt"\n)))
      .to eq(['GET /', 'GET /files/*path', 'GET /ledgers/:ledger_id/entries(/:page)'])
  end

  it 'matches the literal root path without a helper' do
    expect(exercised(%(visit "/"\n))).to eq(['GET /'])
  end

  it 'uses the identifier the route unit carries, constraints included' do
    expect(exercised(%(get "/api/widgets"\n))).to eq(['GET /api/widgets [subdomain=api]'])
  end

  it 'accepts page.visit and main_app helpers' do
    expect(exercised("page.visit widgets_path\nvisit main_app.new_widget_path\n"))
      .to eq(['GET /widgets', 'GET /widgets/new'])
  end

  it 'emits nothing for an unknown helper, an unrouted path, or a verb the path does not accept' do
    expect(exercised(%(visit ghost_path\nvisit "/nowhere"\ndelete widgets_path\nput "/widgets"\n))).to eq([])
  end

  it 'ignores commented calls, other receivers, symbols, and absolute URLs' do
    source = <<~RUBY
      # visit widgets_path
      cache.get "/widgets"
      get :index
      visit "https://example.test/widgets"
      target = widget_path(widget)
      @client.post "/widgets"
    RUBY

    expect(exercised(source)).to eq([])
  end

  it 'skips a literal whose interpolation holds a quote' do
    source = <<~'RUBY'
      visit "/widgets/#{params["id"]}"
    RUBY

    expect(exercised(source)).to eq([])
  end

  describe 'subdomain-constrained routes' do
    let(:routes) do
      [
        route_double(verb: 'GET', path: '/settings', controller: 'settings', action: 'show',
                     constraints: { subdomain: 'app' }),
        route_double(verb: 'GET', path: '/:id', controller: 'shops', action: 'show',
                     constraints: { subdomain: 'shop' }),
        route_double(verb: 'GET', path: '/status', controller: 'api/status', action: 'show',
                     constraints: { subdomain: /\Aapi\d*\z/ }),
        route_double(verb: 'GET', path: '/about', controller: 'pages', action: 'about', name: 'about'),
        route_double(verb: 'GET', path: '/:slug', controller: 'pages', action: 'show')
      ]
    end

    def analysis(source)
      described_class.new.analyze(source)
    end

    it 'prefers the one static route over wildcard routes on other subdomains when the subdomain is unknown' do
      result = analysis(%(visit "/settings"\nvisit "/about"\n))

      expect(result.exercised).to eq(['GET /about', 'GET /settings [subdomain=app]'])
      expect(result.ambiguous).to eq([])
    end

    it 'records candidates and emits nothing when only wildcard routes compete' do
      result = analysis(%(visit "/pricing"\n))

      expect(result.exercised).to eq([])
      expect(result.ambiguous).to eq(
        [{ request: 'GET /pricing', candidates: ['GET /:id [subdomain=shop]', 'GET /:slug'] }]
      )
    end

    it 'follows route order among the routes a known subdomain satisfies' do
      shop = analysis(%(host! "shop.example.test"\nvisit "/settings"\nvisit "/about"\n))
      app = analysis(%(before { host!("app.example.test") }\nvisit "/settings"\nvisit "/pricing"\n))

      expect(shop.exercised).to eq(['GET /:id [subdomain=shop]'])
      expect(app.exercised).to eq(['GET /:slug', 'GET /settings [subdomain=app]'])
      expect(shop.ambiguous + app.ambiguous).to eq([])
    end

    it 'reads the subdomain from an option, a helper call, and the Capybara app host' do
      ['visit root_url(subdomain: "shop")', 'get "/x", :subdomain => :shop', 'with_subdomain("shop") { }',
       'use_subdomain :shop', 'Capybara.app_host = "http://shop.example.test:3000"'].each do |line|
        expect(analysis(%(#{line}\nvisit "/pricing"\n)).exercised).to eq(['GET /:id [subdomain=shop]']), line
      end
    end

    it 'matches a known subdomain against a pattern constraint' do
      expect(analysis(%(host! "api2.example.test"\nvisit "/status"\n)).exercised)
        .to eq(['GET /status [subdomain=\\Aapi\\d*\\z]'])
      expect(analysis(%(host! "app.example.test"\nvisit "/status"\n)).exercised).to eq(['GET /:slug'])
    end

    it 'treats a host without a subdomain as known, matching only unconstrained routes' do
      expect(analysis(%(host! "example.test"\nvisit "/settings"\n)).exercised).to eq(['GET /:slug'])
    end

    it 'exercises the route each named host decides when the file names several' do
      several = analysis(%(host! "shop.example.test"\nhost! "app.example.test"\nvisit "/pricing"\n))

      expect(several.exercised).to eq(['GET /:id [subdomain=shop]', 'GET /:slug'])
      expect(several.ambiguous).to eq([])
    end

    it 'treats the subdomain as unknown when the file interpolates one' do
      dynamic = analysis("host! \"\#{shop.subdomain}.example.test\"\nhost! \"app.example.test\"\nvisit \"/pricing\"\n")

      expect(dynamic.exercised).to eq([])
      expect(dynamic.ambiguous.size).to eq(1)
    end

    it 'follows config.test_subdomain_helpers' do
      original = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      Woods.configuration.test_subdomain_helpers = ['on_storefront']

      expect(analysis(%(on_storefront "shop"\nvisit "/pricing"\n)).exercised).to eq(['GET /:id [subdomain=shop]'])
      expect(analysis(%(with_subdomain "shop"\nvisit "/pricing"\n)).exercised).to eq([])
    ensure
      Woods.configuration = original
    end
  end

  describe 'Capybara support defaults and redirect routes' do
    let(:root) { Pathname.new(Dir.mktmpdir('woods_route_defaults')) }
    let(:routes) do
      [
        route_double(verb: 'GET', path: '/settings', controller: 'settings', action: 'show',
                     constraints: { subdomain: 'app' }),
        route_double(verb: 'GET', path: '/settings', controller: 'settings', action: 'show',
                     constraints: { subdomain: 'my' })
      ]
    end

    before { stub_route_set(routes, root: root, logger: logger) }
    after { FileUtils.remove_entry(root) }

    def support_file(path, source)
      file = root.join(path)
      FileUtils.mkdir_p(file.dirname)
      File.write(file, source)
    end

    def analysis(source = %(visit "/settings"\n))
      described_class.new.analyze(source)
    end

    it 'uses Capybara.app_host from spec support when the file names no host' do
      support_file('spec/support/capybara.rb', 'Capybara.app_host = "http://my.example.test:3000"')

      expect(analysis.exercised).to eq(['GET /settings [subdomain=my]'])
    end

    it 'uses Capybara.default_host from rails_helper when the file names no host' do
      support_file('spec/rails_helper.rb', 'Capybara.default_host = "http://my.example.test"')

      expect(analysis.exercised).to eq(['GET /settings [subdomain=my]'])
    end

    it 'uses the configured tld_length for the support host' do
      stub_const('ActionDispatch::Http::URL', double('URL', tld_length: 2))
      support_file('spec/rails_helper.rb', 'Capybara.app_host = "https://my.example.co.test"')

      expect(analysis.exercised).to eq(['GET /settings [subdomain=my]'])
    end

    it 'prefers app_host over default_host' do
      support_file('spec/rails_helper.rb', <<~RUBY)
        Capybara.default_host = "http://app.example.test"
        Capybara.app_host = "http://my.example.test"
      RUBY

      expect(analysis.exercised).to eq(['GET /settings [subdomain=my]'])
    end

    it 'reads a literal default subdomain helper call from support' do
      support_file('spec/support/capybara.rb', <<~'RUBY')
        def use_subdomain(subdomain)
          Capybara.app_host = "http://#{subdomain}.example.test"
        end
        RSpec.configure { |config| config.before { use_subdomain "my" } }
      RUBY

      expect(analysis.exercised).to eq(['GET /settings [subdomain=my]'])
    end

    it 'reads a literal support host beside a host an unconfigured helper interpolates' do
      support_file('spec/support/capybara.rb', <<~'RUBY')
        def use_default_host
          Capybara.app_host = "http://my.example.test:#{port}"
        end

        def set_testing_subdomain(sub)
          Capybara.app_host = "http://#{sub}.example.test:#{port}"
        end
      RUBY

      expect(analysis.exercised).to eq(['GET /settings [subdomain=my]'])
    end

    it 'keeps an explicit file host ahead of the support default' do
      support_file('spec/rails_helper.rb', 'Capybara.app_host = "http://my.example.test"')

      expect(analysis(%(host! "app.example.test"\nvisit "/settings"\n)).exercised)
        .to eq(['GET /settings [subdomain=app]'])
    end

    it 'exercises one route per named host when each host picks a different route' do
      result = analysis(<<~RUBY)
        context("app") { before { host! "app.example.test" } }
        context("my") { before { host! "my.example.test" } }
        visit "/settings"
      RUBY

      expect(result.exercised).to eq(['GET /settings [subdomain=app]', 'GET /settings [subdomain=my]'])
      expect(result.ambiguous).to eq([])
    end

    it 'reports a request no named host decides as ambiguous, without an edge' do
      status = route_double(verb: 'GET', path: '/status', controller: 'status', action: 'show',
                            constraints: { subdomain: 'api' })
      stub_route_set([*routes, status], root: root, logger: logger)
      result = analysis(%(host! "app.example.test"\nhost! "my.example.test"\nvisit "/settings"\nvisit "/status"\n))

      expect(result.exercised).to eq(['GET /settings [subdomain=app]', 'GET /settings [subdomain=my]'])
      expect(result.ambiguous).to eq([{ request: 'GET /status', candidates: ['GET /status [subdomain=api]'] }])
    end

    it 'preserves ambiguity when no default host is configured' do
      result = analysis

      expect(result.exercised).to eq([])
      expect(result.ambiguous).to eq(
        [{ request: 'GET /settings', candidates: ['GET /settings [subdomain=app]', 'GET /settings [subdomain=my]'] }]
      )
    end

    it 'lets a redirect win over a route on a different subdomain' do
      stub_const('ActionDispatch::Routing::Redirect', Struct.new(:block, :status))
      redirect = route_double(verb: 'GET', path: '/settings', controller: nil, action: nil,
                              constraints: { subdomain: 'my' })
      allow(redirect).to receive(:app).and_return(ActionDispatch::Routing::Redirect.new('/profile', 302))
      stub_route_set([routes.first, redirect], root: root, logger: logger)
      support_file('spec/rails_helper.rb', 'Capybara.app_host = "http://my.example.test"')

      result = analysis(%(visit "/settings"\nexpect(page).to have_current_path("/settings")\n))
      expect(result.exercised).to eq(['GET /settings [subdomain=my] (redirect)'])
      expect(result.asserted).to eq(['GET /settings [subdomain=my] (redirect)'])
      expect(result.ambiguous).to eq([])
    end

    it 'lists a subdomain-constrained redirect only when a named or default host reaches it' do
      stub_const('ActionDispatch::Routing::Redirect', Struct.new(:block, :status))
      redirect = route_double(verb: 'GET', path: '/settings', controller: nil, action: nil,
                              constraints: { subdomain: 'old' })
      allow(redirect).to receive(:app).and_return(ActionDispatch::Routing::Redirect.new('/profile', 301))
      stub_route_set([*routes, redirect], root: root, logger: logger)
      dynamic = "host! \"\#{shop.subdomain}.example.test\"\n"

      expect(analysis.ambiguous).to eq(
        [{ request: 'GET /settings', candidates: ['GET /settings [subdomain=app]', 'GET /settings [subdomain=my]'] }]
      )
      expect(analysis(%(#{dynamic}host! "old.example.test"\nvisit "/settings"\n)).ambiguous.first[:candidates])
        .to include('GET /settings [subdomain=old] (redirect)')
      expect(analysis(%(host! "old.example.test"\nvisit "/settings"\n)).exercised)
        .to eq(['GET /settings [subdomain=old] (redirect)'])
    end

    describe 'a file with no host hint and a configured support helper' do
      let(:routes) do
        stub_const('ActionDispatch::Routing::Redirect', Struct.new(:block, :status))
        redirect = route_double(verb: 'GET', path: '/settings', controller: nil, action: nil,
                                constraints: { subdomain: 'my' })
        allow(redirect).to receive(:app).and_return(ActionDispatch::Routing::Redirect.new('/profile', 302))
        [route_double(verb: 'GET', path: '/settings', controller: 'settings', action: 'show',
                      constraints: { subdomain: 'app' }), redirect]
      end

      around do |example|
        original = Woods.configuration
        Woods.configuration = Woods::Configuration.new
        Woods.configuration.test_subdomain_helpers = ['set_testing_subdomain']
        example.run
      ensure
        Woods.configuration = original
      end

      before do
        support_file('spec/support/subdomains.rb', <<~'RUBY')
          def set_testing_subdomain(sub)
            Capybara.app_host = "http://#{sub}.example.test:#{port}"
          end
        RUBY
        support_file('spec/support/tenant_host.rb', <<~'RUBY')
          Capybara.app_host = "http://#{tenant}.example.test"
        RUBY
      end

      it 'resolves on the literal default, which helper literals widen but never cancel' do
        support_file('spec/support/capybara.rb', <<~'RUBY')
          RSpec.configure { |config| config.before { Capybara.app_host = "http://my.example.test:#{port}" } }
        RUBY
        support_file('spec/support/login_helpers.rb',
                     "module LoginHelpers\n  def login_to_store\n    set_testing_subdomain 'my'\n  end\nend\n")
        support_file('spec/support/app_helpers.rb', "def visit_app\n  set_testing_subdomain 'app'\nend\n")
        result = analysis(%(include LoginHelpers\nbefore { login_to_store }\nvisit "/settings"\n))

        expect(result.exercised).to eq(['GET /settings [subdomain=my] (redirect)'])
        expect(result.ambiguous).to eq([])
      end

      it 'stays ambiguous when the default is unknown, rather than let filtering pick the plain route' do
        result = analysis

        expect(result.exercised).to eq([])
        expect(result.ambiguous).to eq(
          [{ request: 'GET /settings',
             candidates: ['GET /settings [subdomain=app]', 'GET /settings [subdomain=my] (redirect)'] }]
        )
      end
    end

    describe 'request specs' do
      let(:routes) do
        [route_double(verb: 'GET', path: '/account', controller: 'accounts', action: 'show',
                      constraints: { subdomain: 'app' }),
         route_double(verb: 'GET', path: '/account', controller: 'accounts', action: 'show',
                      constraints: { subdomain: 'my' }),
         route_double(verb: 'GET', path: '/health', controller: 'health', action: 'show')]
      end
      let(:both) { ['GET /account [subdomain=app]', 'GET /account [subdomain=my]'] }

      before { support_file('spec/rails_helper.rb', 'Capybara.app_host = "http://my.example.test"') }

      it 'leaves the host unknown for a non-literal host!, ignoring the Capybara default' do
        result = analysis(<<~RUBY)
          def sign_in_to_api
            host! Rails.configuration.app_domain
          end
          before { sign_in_to_api }
          it { get '/account.json' }
          it { get '/health' }
        RUBY

        expect(result.exercised).to eq(['GET /health'])
        expect(result.ambiguous).to eq([{ request: 'GET /account.json', candidates: both }])
      end

      it 'does not give a request spec without host! the Capybara default' do
        expect(analysis(%(get "/account"\n)).ambiguous).to eq([{ request: 'GET /account', candidates: both }])
      end

      it 'gives the Capybara default to a feature or system tag, or the acceptance helper' do
        ["RSpec.describe 'Account', type: :feature do\n", "describe 'Account', :type => :system do\n",
         "require 'acceptance_helper'\n"].each do |line|
          expect(analysis(%(#{line}get "/account"\n)).exercised).to eq(['GET /account [subdomain=my]']), line
        end
      end
    end

    it 'prefers a matching subdomain constraint over an earlier unconstrained route' do
      fallback = route_double(verb: 'GET', path: '/settings', controller: 'pages', action: 'show')
      stub_route_set([fallback, *routes], root: root, logger: logger)

      expect(analysis(%(host! "my.example.test"\nvisit "/settings"\n)).exercised)
        .to eq(['GET /settings [subdomain=my]'])
    end

    it 'does not assume a matching callable constraint passes' do
      fallback = route_double(verb: 'GET', path: '/settings', controller: 'pages', action: 'show')
      constrained = route_double(verb: 'GET', path: '/settings', controller: 'settings', action: 'show',
                                 constraints: { subdomain: 'my' }, callable: true)
      stub_route_set([fallback, constrained], root: root, logger: logger)

      result = analysis(%(host! "my.example.test"\nvisit "/settings"\n))
      expect(result.exercised).to eq([])
      expect(result.ambiguous).to eq(
        [{ request: 'GET /settings', candidates: ['GET /settings', 'GET /settings [subdomain=my, constraint=proc]'] }]
      )
    end
  end

  describe 'routes behind a callable constraint' do
    let(:routes) do
      [
        route_double(verb: 'GET', path: '/dashboard', controller: 'staff/dashboards', action: 'show', callable: true),
        route_double(verb: 'GET', path: '/dashboard', controller: 'dashboards', action: 'show'),
        route_double(verb: 'GET', path: '/reports', controller: 'reports', action: 'index', callable: true)
      ]
    end

    it 'does not guess whether the constraint passes' do
      result = described_class.new.analyze(%(visit "/dashboard"\nvisit "/reports"\n))

      expect(result.exercised).to eq(['GET /reports [constraint=proc]'])
      expect(result.ambiguous).to eq(
        [{ request: 'GET /dashboard', candidates: ['GET /dashboard', 'GET /dashboard [constraint=proc]'] }]
      )
    end
  end

  describe 'paths inside assertions' do
    it 'records an asserted route without counting it as exercised' do
      source = <<~RUBY
        get widgets_path
        expect(response).to redirect_to(new_widget_path)
        expect(page).to have_current_path("/widgets/7")
        assert_redirected_to widget_url(widget)
        expect(page).to have_current_path(ghost_path)
      RUBY

      result = described_class.new.analyze(source)
      expect(result.exercised).to eq(['GET /widgets'])
      expect(result.asserted).to eq(['GET /widgets/:id', 'GET /widgets/new'])
    end
  end

  it 'returns nothing when the route set is unavailable' do
    stub_const('Rails', double('Rails', root: Pathname.new(Dir.tmpdir), logger: logger))

    expect(exercised("visit widgets_path\n")).to eq([])
  end
end
