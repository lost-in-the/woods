# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/concern'
require 'active_support/core_ext/string/inflections'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/class/subclasses'
require 'woods'
require 'woods/extractors/controller_extractor'
require 'woods/dependency_graph'
require 'woods/graph_analyzer'

# Which public methods count as a controller's actions, and where each one
# is defined.
#
# The fixtures are real Ruby loaded from files under a temporary app root,
# so +source_location+, +owner+ and +ancestors+ are Ruby's own answers. The
# framework base is a stand-in that computes +action_methods+ the way
# AbstractController does: every public method below the abstract base.
RSpec.describe Woods::Extractors::ControllerExtractor, 'action selection' do
  let(:app_root) { Dir.mktmpdir('woods_actions_app') }
  let(:gem_root) { Dir.mktmpdir('woods_actions_gem') }

  after do
    FileUtils.rm_rf(app_root)
    FileUtils.rm_rf(gem_root)
  end

  def write(root, relative, content)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def load_app(relative, content)
    load write(app_root, relative, content)
  end

  def route(controller, action)
    double('Route',
           defaults: { controller: controller, action: action },
           path: double(spec: double(to_s: "/#{controller}/#{action}(.:format)")),
           verb: 'GET', name: nil, constraints: {})
  end

  def build_extractor(routes, named_routes: {})
    routes_double = double('Routes', routes: routes, named_routes: named_routes)
    app_double = double('Application', routes: routes_double)
    stub_const('Rails', double('Rails', application: app_double, root: Pathname.new(app_root),
                                        logger: double('Logger', error: nil, warn: nil, debug: nil, info: nil)))
    stub_const('ActionController::Metal', ActionFixtures::FrameworkMetal)
    stub_const('ActionController::Base', ActionFixtures::FrameworkBase)
    stub_const('ActionController::API', ActionFixtures::FrameworkBase)
    described_class.new
  end

  before do
    stub_const('ActionFixtures', Module.new)
    # The bare Rack-level root, like ActionController::Metal: it has actions
    # but no callback chain until a callbacks module is included.
    metal = Class.new do
      def self.action_methods
        (public_instance_methods(true) - ActionFixtures::FrameworkMetal.public_instance_methods(true))
          .to_set(&:to_s)
      end
    end
    ActionFixtures.const_set(:FrameworkMetal, metal)
    framework = Class.new(metal) do
      def self._process_action_callbacks = []
    end
    ActionFixtures.const_set(:FrameworkBase, framework)

    # A gem module in the style of AbstractController::Callbacks: including
    # it gives a Metal controller a callback chain and a public helper.
    load write(gem_root, 'lib/fake_callbacks.rb', <<~RUBY)
      module ActionFixtures
        module FakeCallbacks
          def self.included(base)
            base.define_singleton_method(:_process_action_callbacks) { [] }
          end

          def performed? = false
        end
      end
    RUBY

    # A gem DSL in the style of decent_exposure: define_method from a file
    # outside the app root creates a public reader and writer.
    load write(gem_root, 'lib/fake_exposure.rb', <<~RUBY)
      module ActionFixtures
        module FakeExposure
          def expose(name)
            define_method(name) { name }
            define_method("\#{name}=") { |value| value }
          end
        end
      end
    RUBY

    load_app('app/controllers/action_fixtures/base_controller.rb', <<~RUBY)
      class ActionFixtures::BaseController < ActionFixtures::FrameworkBase
        def current_ledger = nil
      end
    RUBY

    load_app('app/controllers/concerns/action_fixtures/sso_behavior.rb', <<~RUBY)
      module ActionFixtures::SsoBehavior
        extend ActiveSupport::Concern

        def create
          Ledger.verify!
        end

        def paginate_params = {}
      end
    RUBY

    load_app('app/controllers/action_fixtures/sso_google_controller.rb', <<~RUBY)
      class ActionFixtures::SsoGoogleController < ActionFixtures::BaseController
        include ActionFixtures::SsoBehavior

        private

        def current_provider = :google
      end
    RUBY

    load_app('app/controllers/action_fixtures/modern/confirmations_controller.rb', <<~RUBY)
      module ActionFixtures::Modern; end

      class ActionFixtures::Modern::ConfirmationsController < ActionFixtures::BaseController
        module Behavior
          extend ActiveSupport::Concern

          def new = nil

          def create
            Shipment.confirm!
          end
        end
        prepend Behavior

        private def default_landing_path = :modern_home
      end
    RUBY

    load_app('app/controllers/action_fixtures/confirmations_controller.rb', <<~RUBY)
      class ActionFixtures::ConfirmationsController < ActionFixtures::BaseController
        prepend ActionFixtures::Modern::ConfirmationsController::Behavior

        private def default_landing_path = :home
      end
    RUBY

    load_app('app/controllers/action_fixtures/base_reports_controller.rb', <<~RUBY)
      class ActionFixtures::BaseReportsController < ActionFixtures::BaseController
        def show = nil
        def export = nil
      end
    RUBY

    load_app('app/controllers/action_fixtures/sales_reports_controller.rb', <<~RUBY)
      class ActionFixtures::SalesReportsController < ActionFixtures::BaseReportsController
        private def report = :sales

        private def back = redirect_to(base_reports_path)
      end
    RUBY

    # An app-side DSL in lib/ that defines methods on the controller from
    # its own file.
    load_app('lib/action_fixtures/report_dsl.rb', <<~RUBY)
      module ActionFixtures
        module ReportDsl
          def report_columns(*names)
            names.each { |name| define_method(name) { name } }
          end
        end
      end
    RUBY

    load_app('app/controllers/action_fixtures/ledgers_controller.rb', <<~RUBY)
      class ActionFixtures::LedgersController < ActionFixtures::BaseController
        extend ActionFixtures::ReportDsl
        report_columns :summary, :totals

        def index = nil
      end
    RUBY

    load_app('app/controllers/action_fixtures/widgets_controller.rb', <<~RUBY)
      class ActionFixtures::WidgetsController < ActionFixtures::BaseController
        extend ActionFixtures::FakeExposure
        expose :widget

        def index = nil
        def widget_name=(value)
          @widget_name = value
        end
      end
    RUBY

    # A gem controller in the style of an authentication engine's
    # sessions controller, and an app controller that inherits from it.
    load write(gem_root, 'app/controllers/action_fixtures/vault/sessions_controller.rb', <<~RUBY)
      module ActionFixtures::Vault; end

      class ActionFixtures::Vault::SessionsController < ActionFixtures::FrameworkBase
        def new = nil
        def create = nil
        def destroy = nil
      end
    RUBY

    load_app('app/controllers/action_fixtures/members/sessions_controller.rb', <<~RUBY)
      module ActionFixtures::Members; end

      class ActionFixtures::Members::SessionsController < ActionFixtures::Vault::SessionsController
        def new = super
      end
    RUBY

    load_app('app/controllers/action_fixtures/health_controller.rb', <<~RUBY)
      class ActionFixtures::HealthController < ActionFixtures::FrameworkMetal
        def show
          [200, { 'content-type' => 'text/plain' }, ['ok']]
        end

        private def checks = []
      end
    RUBY

    load_app('app/controllers/action_fixtures/ping_controller.rb', <<~RUBY)
      class ActionFixtures::PingController < ActionFixtures::FrameworkMetal
        include ActionFixtures::FakeCallbacks

        def index = [204, {}, []]
      end
    RUBY
  end

  let(:extractor) do
    build_extractor([
                      route('action_fixtures/sso_google', 'create'),
                      route('action_fixtures/confirmations', 'new'),
                      route('action_fixtures/confirmations', 'create'),
                      route('action_fixtures/modern/confirmations', 'create'),
                      route('action_fixtures/sales_reports', 'show'),
                      route('action_fixtures/ledgers', 'totals'),
                      route('action_fixtures/health', 'show'),
                      route('action_fixtures/members/sessions', 'new'),
                      route('action_fixtures/members/sessions', 'create'),
                      route('action_fixtures/widgets', 'widget')
                    ], named_routes: { base_reports: route('action_fixtures/base_reports', 'show') })
  end

  def unit_for(name)
    extractor.extract_controller(ActionFixtures.const_get(name))
  end

  describe 'an action from an included app concern' do
    subject(:unit) { unit_for('SsoGoogleController') }

    it 'is an action of the including controller when routed, unlike the concern’s unrouted helper' do
      expect(unit.metadata[:actions]).to contain_exactly('create')
    end

    it 'records the concern as the defining unit, with file and line' do
      expect(unit.metadata[:action_sources]['create']).to eq(
        owner: 'ActionFixtures::SsoBehavior',
        defined_in: 'ActionFixtures::SsoBehavior',
        file: 'app/controllers/concerns/action_fixtures/sso_behavior.rb',
        line: 4
      )
    end

    it 'keeps a dependency edge to the concern' do
      expect(unit.dependencies).to include(a_hash_including(type: :concern, target: 'ActionFixtures::SsoBehavior'))
    end
  end

  describe 'actions from a module nested in another controller and prepended' do
    it 'are actions of the controller that prepends the module' do
      expect(unit_for('ConfirmationsController').metadata[:actions]).to contain_exactly('new', 'create')
    end

    it 'are actions of the controller that holds the module only where routed' do
      expect(unit_for('Modern::ConfirmationsController').metadata[:actions]).to contain_exactly('create')
    end

    it 'resolve to the controller whose file holds the module' do
      source = unit_for('ConfirmationsController').metadata[:action_sources]['create']

      expect(source).to eq(
        owner: 'ActionFixtures::Modern::ConfirmationsController::Behavior',
        defined_in: 'ActionFixtures::Modern::ConfirmationsController',
        file: 'app/controllers/action_fixtures/modern/confirmations_controller.rb',
        line: 9
      )
    end

    it 'adds an action_source edge from the twin to the holding controller' do
      expect(unit_for('ConfirmationsController').dependencies).to include(
        { type: :controller, target: 'ActionFixtures::Modern::ConfirmationsController', via: :action_source }
      )
    end

    it 'adds no edge from the holding controller to itself' do
      targets = unit_for('Modern::ConfirmationsController').dependencies.map { |dep| dep[:target] }

      expect(targets).not_to include('ActionFixtures::Modern::ConfirmationsController')
    end
  end

  describe 'actions inherited from an app base controller' do
    subject(:unit) { unit_for('SalesReportsController') }

    it 'admits only the inherited actions routed to this controller' do
      expect(unit.metadata[:actions]).to contain_exactly('show')
    end

    it 'records the base controller as the defining unit and depends on it' do
      expect(unit.metadata[:action_sources]['show']).to include(defined_in: 'ActionFixtures::BaseReportsController')
      expect(unit.dependencies).to include(
        { type: :controller, target: 'ActionFixtures::BaseReportsController', via: :action_source }
      )
    end

    it 'keeps a redirect_to edge to the parent alongside the inheritance and action_source edges' do
      Woods.configure unless Woods.configuration
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(true)

      to_parent = unit.dependencies.select { |dep| dep[:target] == 'ActionFixtures::BaseReportsController' }

      expect(to_parent.map { |dep| dep[:via] }).to contain_exactly(:action_source, :inheritance, :redirect_to)
    end

    it 'depends on an app parent controller even when no action comes from it, but not on a framework base' do
      expect(unit_for('WidgetsController').dependencies).to include(
        { type: :controller, target: 'ActionFixtures::BaseController', via: :inheritance }
      )
      expect(unit_for('BaseController').dependencies.map { |dep| dep[:via] }).not_to include(:inheritance)
    end

    it 'keeps unrouted public methods of the controller that defines them' do
      expect(unit_for('BaseReportsController').metadata[:actions]).to contain_exactly('show', 'export')
      expect(unit_for('BaseController').metadata[:actions]).to contain_exactly('current_ledger')
    end
  end

  describe 'methods an app DSL defines on the controller from another file' do
    it 'are actions only when routed, while methods in the controller’s own file are actions regardless' do
      expect(unit_for('LedgersController').metadata[:actions]).to contain_exactly('index', 'totals')
    end
  end

  describe 'methods a gem DSL defines on the controller' do
    subject(:unit) { unit_for('WidgetsController') }

    it 'are not actions, while the controller’s own method is' do
      expect(unit.metadata[:actions]).to contain_exactly('index')
    end

    it 'records a local action as defined in the controller itself' do
      expect(unit.metadata[:action_sources]['index']).to eq(
        owner: 'ActionFixtures::WidgetsController',
        defined_in: 'ActionFixtures::WidgetsController',
        file: 'app/controllers/action_fixtures/widgets_controller.rb',
        line: 5
      )
    end

    it 'counts only admitted actions' do
      expect(unit.metadata[:action_count]).to eq(1)
    end
  end

  describe 'Metal controllers defined in app source' do
    it 'are discovered alongside Base and API controllers' do
      expect(extractor.discoverable_classes).to include(ActionFixtures::HealthController, ActionFixtures::PingController)
    end

    it 'become controller units flagged as metal, with actions per the admission rule' do
      unit = unit_for('HealthController')

      expect(unit.type).to eq(:controller)
      expect(unit.metadata).to include(metal: true, actions: ['show'], filters: [], filter_count: 0)
    end

    it 'stop the ancestor chain at the Metal root' do
      expect(unit_for('HealthController').metadata[:ancestors]).to eq(['ActionFixtures::HealthController'])
    end

    it 'chunk their actions without a callback chain' do
      expect(unit_for('HealthController').chunks.map { |chunk| chunk[:identifier] })
        .to eq(['ActionFixtures::HealthController#show'])
    end

    it 'admit an own-file action but not the public helper an included gem module adds' do
      expect(unit_for('PingController').metadata).to include(metal: true, actions: ['index'])
    end

    it 'leave Base controllers unflagged' do
      expect(unit_for('WidgetsController').metadata[:metal]).to be(false)
    end

    it 'resolve the routes that dispatch to them' do
      graph = Woods::DependencyGraph.new
      graph.register(unit_for('HealthController'))
      graph.register(Woods::ExtractedUnit.new(type: :route, identifier: 'GET /health', file_path: nil).tap do |route|
        route.metadata = { controller: 'action_fixtures/health', action: 'show' }
        route.dependencies = [{ type: :controller, target: 'ActionFixtures::HealthController', via: :route_dispatch }]
      end)

      expect(Woods::GraphAnalyzer.new(graph).unresolvable_routes).to eq([])
    end
  end

  describe 'routed actions whose body is gem code' do
    subject(:unit) { unit_for('Members::SessionsController') }

    def route_unit(identifier, controller, action)
      Woods::ExtractedUnit.new(type: :route, identifier: identifier, file_path: nil).tap do |route|
        route.metadata = { controller: controller.underscore.delete_suffix('_controller'), action: action }
        route.dependencies = [{ type: :controller, target: controller, via: :route_dispatch }]
      end
    end

    def graph_with(*units)
      Woods::DependencyGraph.new.tap { |graph| units.each { |unit| graph.register(unit) } }
    end

    it 'are not admitted as actions, while the controller’s own override is' do
      expect(unit.metadata[:actions]).to eq(['new'])
    end

    it 'are recorded with their gem owner, leaving unrouted gem actions out' do
      expect(unit.metadata[:inherited_gem_actions]).to eq(
        'create' => { owner: 'ActionFixtures::Vault::SessionsController' }
      )
    end

    it 'add no edge into the gem class' do
      expect(unit.dependencies.map { |dep| dep[:target] }).not_to include('ActionFixtures::Vault::SessionsController')
    end

    it 'include a routed reader a gem DSL defines on the controller itself' do
      expect(unit_for('WidgetsController').metadata[:inherited_gem_actions]).to eq(
        'widget' => { owner: 'ActionFixtures::WidgetsController' }
      )
    end

    it 'record an empty set on a controller with none' do
      expect(unit_for('LedgersController').metadata[:inherited_gem_actions]).to eq({})
    end

    it 'keep a route to them out of the unresolvable-route report' do
      controller = 'ActionFixtures::Members::SessionsController'
      graph = graph_with(unit, route_unit('POST /members/sessions', controller, 'create'),
                         route_unit('DELETE /members/sessions', controller, 'reset'))
      restored = Woods::DependencyGraph.from_h(JSON.parse(JSON.generate(graph.to_h)))

      [graph, restored].each do |candidate|
        expect(Woods::GraphAnalyzer.new(candidate).unresolvable_routes)
          .to eq([{ route: 'DELETE /members/sessions', controller: controller, action: 'reset',
                    reason: 'missing_action' }])
      end
    end
  end

  describe 'per-action chunks' do
    def chunk_actions(name)
      unit_for(name).chunks.map { |chunk| chunk[:metadata][:action] }
    end

    it 'cover exactly the admitted actions, leaving out gem-inherited ones' do
      expect(chunk_actions('Members::SessionsController')).to contain_exactly('new')
    end

    it 'leave out gem DSL readers and setters' do
      expect(chunk_actions('WidgetsController')).to contain_exactly('index')
    end

    it 'leave out unrouted mixin helpers while keeping a routed inherited action' do
      expect(chunk_actions('SsoGoogleController')).to contain_exactly('create')
      expect(chunk_actions('SalesReportsController')).to contain_exactly('show')
    end
  end
end
