# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extractors/controller_extractor'

RSpec.describe Woods::Extractors::ControllerExtractor do
  # ── Test doubles ──────────────────────────────────────────────────────
  #
  # Mock ActionFilter: an object with an @actions ivar (Set of strings),
  # matching how Rails stores :only/:except since 4.2.
  #
  # Mock Callback: an object with @if/@unless arrays, .kind, and .filter,
  # matching ActiveSupport::Callbacks::Callback's interface.

  def build_action_filter(actions)
    obj = Object.new
    obj.instance_variable_set(:@actions, Set.new(actions.map(&:to_s)))
    obj
  end

  def build_callback(kind:, filter:, if_conditions: [], unless_conditions: [])
    obj = Object.new
    obj.instance_variable_set(:@if, if_conditions)
    obj.instance_variable_set(:@unless, unless_conditions)
    obj.define_singleton_method(:kind) { kind }
    obj.define_singleton_method(:filter) { filter }
    obj
  end

  # We test the private helpers by sending them through a fresh instance.
  # The extractor needs Rails.application.routes to initialize, so we stub that.
  let(:extractor) do
    routes_double = double('Routes', routes: [], named_routes: {})
    app_double = double('Application', routes: routes_double)
    stub_const('Rails', double('Rails', application: app_double))
    described_class.new
  end

  # ── extract_callback_conditions ──────────────────────────────────────

  describe '#extract_callback_conditions' do
    it 'extracts :only actions from @if ActionFilter' do
      filter = build_action_filter(%w[create update])
      callback = build_callback(kind: :before, filter: :authenticate!, if_conditions: [filter])

      only, except, if_labels, unless_labels = extractor.send(:extract_callback_conditions, callback)

      expect(only).to match_array(%w[create update])
      expect(except).to be_empty
      expect(if_labels).to be_empty
      expect(unless_labels).to be_empty
    end

    it 'extracts :except actions from @unless ActionFilter' do
      filter = build_action_filter(%w[index show])
      callback = build_callback(kind: :before, filter: :require_login, unless_conditions: [filter])

      only, except, if_labels, unless_labels = extractor.send(:extract_callback_conditions, callback)

      expect(only).to be_empty
      expect(except).to match_array(%w[index show])
      expect(if_labels).to be_empty
      expect(unless_labels).to be_empty
    end

    it 'handles mixed ActionFilter and proc conditions' do
      action_filter = build_action_filter(%w[destroy])
      proc_condition = proc { true }
      callback = build_callback(
        kind: :before, filter: :verify_admin,
        if_conditions: [action_filter, proc_condition]
      )

      only, _, if_labels, _unless_labels = extractor.send(:extract_callback_conditions, callback)

      expect(only).to eq(%w[destroy])
      expect(if_labels).to eq(['Proc'])
    end

    it 'handles callbacks with no conditions' do
      callback = build_callback(kind: :before, filter: :set_locale)

      only, except, if_labels, unless_labels = extractor.send(:extract_callback_conditions, callback)

      expect(only).to be_empty
      expect(except).to be_empty
      expect(if_labels).to be_empty
      expect(unless_labels).to be_empty
    end

    it 'handles symbol conditions' do
      callback = build_callback(kind: :before, filter: :check_role, if_conditions: [:admin?])

      _only, _except, if_labels, _unless_labels = extractor.send(:extract_callback_conditions, callback)

      expect(if_labels).to eq([':admin?'])
    end
  end

  # ── callback_applies_to_action? ──────────────────────────────────────

  describe '#callback_applies_to_action?' do
    it 'returns true when action is in :only list' do
      filter = build_action_filter(%w[create update])
      callback = build_callback(kind: :before, filter: :auth, if_conditions: [filter])

      expect(extractor.send(:callback_applies_to_action?, callback, 'create')).to be true
    end

    it 'returns false when action is NOT in :only list' do
      filter = build_action_filter(%w[create update])
      callback = build_callback(kind: :before, filter: :auth, if_conditions: [filter])

      expect(extractor.send(:callback_applies_to_action?, callback, 'index')).to be false
    end

    it 'returns false when action is in :except list' do
      filter = build_action_filter(%w[index show])
      callback = build_callback(kind: :before, filter: :auth, unless_conditions: [filter])

      expect(extractor.send(:callback_applies_to_action?, callback, 'index')).to be false
    end

    it 'returns true when action is NOT in :except list' do
      filter = build_action_filter(%w[index show])
      callback = build_callback(kind: :before, filter: :auth, unless_conditions: [filter])

      expect(extractor.send(:callback_applies_to_action?, callback, 'create')).to be true
    end

    it 'returns true when no conditions present (applies to all)' do
      callback = build_callback(kind: :before, filter: :set_locale)

      expect(extractor.send(:callback_applies_to_action?, callback, 'anything')).to be true
    end

    it 'skips non-ActionFilter conditions (assumes true)' do
      proc_condition = proc { true }
      callback = build_callback(kind: :before, filter: :check, if_conditions: [proc_condition])

      expect(extractor.send(:callback_applies_to_action?, callback, 'index')).to be true
    end
  end

  # ── extract_action_filter_actions ────────────────────────────────────

  describe '#extract_action_filter_actions' do
    it 'returns action names from an ActionFilter' do
      filter = build_action_filter(%w[show edit])

      result = extractor.send(:extract_action_filter_actions, filter)

      expect(result).to match_array(%w[show edit])
    end

    it 'returns nil for a plain proc' do
      result = extractor.send(:extract_action_filter_actions, proc { true })
      expect(result).to be_nil
    end

    it 'returns nil for a symbol' do
      result = extractor.send(:extract_action_filter_actions, :admin?)
      expect(result).to be_nil
    end

    it 'returns nil if @actions is not a Set' do
      obj = Object.new
      obj.instance_variable_set(:@actions, 'not a set')

      result = extractor.send(:extract_action_filter_actions, obj)
      expect(result).to be_nil
    end
  end

  # ── condition_label ──────────────────────────────────────────────────

  describe '#condition_label' do
    it 'labels symbols with colon prefix' do
      expect(extractor.send(:condition_label, :admin?)).to eq(':admin?')
    end

    it "labels procs as 'Proc'" do
      expect(extractor.send(:condition_label, proc { true })).to eq('Proc')
    end

    it 'labels strings as themselves' do
      expect(extractor.send(:condition_label, 'user_signed_in?')).to eq('user_signed_in?')
    end
  end

  # ── source_file_for ───────────────────────────────────────────────────

  describe '#source_file_for' do
    let(:app_root) { '/app' }

    before do
      extractor.instance_variable_get(:@routes_map) # already initialized
      allow(Rails).to receive(:root).and_return(Pathname.new(app_root))
    end

    it 'skips gem paths and falls through to the convention path when the file does not exist' do
      gem_path = '/path/to/gems/decent_exposure/lib/decent_exposure.rb'

      controller = double('Controller')
      allow(controller).to receive(:name).and_return('UsersController')
      allow(controller).to receive(:instance_methods).with(false).and_return([:show])
      allow(controller).to receive(:instance_method).with(:show).and_return(
        double('UnboundMethod', source_location: [gem_path, 10])
      )
      allow(controller).to receive(:methods).with(false).and_return([])

      result = extractor.send(:source_file_for, controller)

      expect(result).not_to eq(gem_path)
      expect(result).to eq("#{app_root}/app/controllers/users_controller.rb")
    end

    it 'returns an instance method path when it is within app root' do
      app_path = "#{app_root}/app/controllers/users_controller.rb"

      controller = double('Controller')
      allow(controller).to receive(:name).and_return('UsersController')
      allow(controller).to receive(:instance_methods).with(false).and_return([:index])
      allow(controller).to receive(:instance_method).with(:index).and_return(
        double('UnboundMethod', source_location: [app_path, 5])
      )

      result = extractor.send(:source_file_for, controller)

      expect(result).to eq(app_path)
    end

    it 'falls through to class methods when instance methods only return gem paths' do
      gem_path = '/path/to/gems/some_gem/lib/some_gem.rb'
      app_path = "#{app_root}/app/controllers/admin_controller.rb"

      controller = double('Controller')
      allow(controller).to receive(:name).and_return('AdminController')
      allow(controller).to receive(:instance_methods).with(false).and_return([:index])
      allow(controller).to receive(:instance_method).with(:index).and_return(
        double('UnboundMethod', source_location: [gem_path, 1])
      )
      allow(controller).to receive(:methods).with(false).and_return([:some_class_method])
      allow(controller).to receive(:method).with(:some_class_method).and_return(
        double('Method', source_location: [app_path, 3])
      )

      result = extractor.send(:source_file_for, controller)

      expect(result).to eq(app_path)
    end

    it 'returns convention path when controller has no instance or class methods' do
      controller = double('Controller')
      allow(controller).to receive(:name).and_return('EmptyController')
      allow(controller).to receive(:instance_methods).with(false).and_return([])
      allow(controller).to receive(:methods).with(false).and_return([])

      result = extractor.send(:source_file_for, controller)

      expect(result).to eq("#{app_root}/app/controllers/empty_controller.rb")
    end

    it 'returns convention path on StandardError' do
      controller = double('Controller')
      allow(controller).to receive(:name).and_return('BrokenController')
      allow(controller).to receive(:instance_methods).with(false).and_raise(StandardError, 'introspection failed')

      result = extractor.send(:source_file_for, controller)

      expect(result).to eq("#{app_root}/app/controllers/broken_controller.rb")
    end
  end

  # ── extract_metadata — own actions only ──────────────────────────────

  describe '#extract_metadata (own actions)' do
    it 'only includes actions defined on the controller itself, not inherited ones' do
      child_own_methods = %i[create update]
      child_action_methods = Set.new(%w[create update inherited_action])

      child_controller = double('ChildController')
      allow(child_controller).to receive(:name).and_return('ChildController')
      allow(child_controller).to receive(:instance_methods).with(false).and_return(child_own_methods)
      allow(child_controller).to receive(:action_methods).and_return(child_action_methods)
      allow(child_controller).to receive(:_process_action_callbacks).and_return([])
      allow(child_controller).to receive(:ancestors).and_return([])
      allow(child_controller).to receive(:included_modules).and_return([])

      # Pass source explicitly so extract_metadata does not call source_file_for
      metadata = extractor.send(:extract_metadata, child_controller, '')

      expect(metadata[:actions]).to match_array(%w[create update])
      expect(metadata[:actions]).not_to include('inherited_action')
    end

    it 'returns empty actions when the controller defines no own methods' do
      controller = double('Controller')
      allow(controller).to receive(:name).and_return('BaseController')
      allow(controller).to receive(:instance_methods).with(false).and_return([])
      allow(controller).to receive(:action_methods).and_return(Set.new(%w[index show]))
      allow(controller).to receive(:_process_action_callbacks).and_return([])
      allow(controller).to receive(:ancestors).and_return([])
      allow(controller).to receive(:included_modules).and_return([])

      # Pass source explicitly so extract_metadata does not call source_file_for
      metadata = extractor.send(:extract_metadata, controller, '')

      expect(metadata[:actions]).to be_empty
    end
  end

  # ── extract_filter_chain (integration) ───────────────────────────────

  describe '#extract_filter_chain' do
    it 'builds filter chain from mocked controller callbacks' do
      only_filter = build_action_filter(%w[create update])
      except_filter = build_action_filter(%w[index])

      callbacks = [
        build_callback(kind: :before, filter: :authenticate_user!, if_conditions: [only_filter]),
        build_callback(kind: :before, filter: :set_locale),
        build_callback(kind: :after, filter: :track_action, unless_conditions: [except_filter])
      ]

      controller = double('Controller', _process_action_callbacks: callbacks)

      chain = extractor.send(:extract_filter_chain, controller)

      expect(chain.size).to eq(3)

      expect(chain[0][:kind]).to eq(:before)
      expect(chain[0][:filter]).to eq(:authenticate_user!)
      expect(chain[0][:only]).to match_array(%w[create update])
      expect(chain[0]).not_to have_key(:except)

      expect(chain[1][:kind]).to eq(:before)
      expect(chain[1][:filter]).to eq(:set_locale)
      expect(chain[1]).not_to have_key(:only)
      expect(chain[1]).not_to have_key(:except)

      expect(chain[2][:kind]).to eq(:after)
      expect(chain[2][:filter]).to eq(:track_action)
      expect(chain[2][:except]).to eq(%w[index])
    end
  end

  # ── redirect scanning (via scan_navigation_dependencies) ──────────

  describe 'redirect scanning via scan_navigation_dependencies' do
    let(:redirect_extractor) do
      posts_route = double('Route',
                           defaults: { controller: 'posts', action: 'index' },
                           path: double(spec: double(to_s: '/posts(.:format)')),
                           verb: 'GET')
      new_post_route = double('Route',
                              defaults: { controller: 'posts', action: 'new' },
                              path: double(spec: double(to_s: '/posts/new(.:format)')),
                              verb: 'GET')
      users_route = double('Route',
                           defaults: { controller: 'users', action: 'index' },
                           path: double(spec: double(to_s: '/users(.:format)')),
                           verb: 'GET')

      named_routes = { posts: posts_route, new_post: new_post_route, users: users_route }
      routes_double = double('Routes', routes: [], named_routes: named_routes)
      app_double = double('Application', routes: routes_double)
      stub_const('Rails', double('Rails', application: app_double, root: Pathname.new('/app')))
      described_class.new
    end

    before do
      Woods.configure unless Woods.configuration
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(true)
    end

    it 'extracts redirect_to with _path helper' do
      source = 'redirect_to posts_path'
      result = redirect_extractor.send(:scan_navigation_dependencies, source, via_type: :redirect_to)
      expect(result).to include(a_hash_including(target: 'PostsController', via: :redirect_to))
    end

    it 'extracts redirect_to with _url helper' do
      source = 'redirect_to users_url'
      result = redirect_extractor.send(:scan_navigation_dependencies, source, via_type: :redirect_to)
      expect(result).to include(a_hash_including(target: 'UsersController', via: :redirect_to))
    end

    it 'deduplicates same controller' do
      source = <<~RUBY
        redirect_to posts_path
        redirect_to new_post_path
      RUBY
      result = redirect_extractor.send(:scan_navigation_dependencies, source, via_type: :redirect_to)
      posts_deps = result.select { |d| d[:target] == 'PostsController' }
      expect(posts_deps.size).to eq(1)
    end

    it 'skips unresolvable helpers' do
      source = 'redirect_to nonexistent_path'
      result = redirect_extractor.send(:scan_navigation_dependencies, source, via_type: :redirect_to)
      expect(result).to be_empty
    end

    it 'returns empty when config is disabled' do
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(false)
      source = 'redirect_to posts_path'
      result = redirect_extractor.send(:scan_navigation_dependencies, source, via_type: :redirect_to)
      expect(result).to be_empty
    end

    it 'ignores redirect_to @model (polymorphic)' do
      source = 'redirect_to @post'
      result = redirect_extractor.send(:scan_navigation_dependencies, source, via_type: :redirect_to)
      expect(result).to be_empty
    end
  end

  # ── discoverable_classes (#200) ──────────────────────────────────────
  #
  # Discovery must start from the ActionController bases: Class#descendants
  # excludes the receiver, so ApplicationController.descendants never
  # yielded ApplicationController itself, and controllers inheriting
  # straight from ActionController::Base were invisible. Framework-internal
  # controllers (gem source) must stay out, and the set must equal what
  # extract_controller accepts — it is the incremental class-reconciliation
  # input (#164).

  describe '#discoverable_classes' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:rails_root) { Pathname.new(tmp_dir) }

    let(:extractor) do
      routes_double = double('Routes', routes: [], named_routes: {})
      app_double = double('Application', routes: routes_double)
      stub_const('Rails', double('Rails', application: app_double, root: rails_root,
                                          logger: double('Logger').as_null_object))
      described_class.new
    end

    after { FileUtils.rm_rf(tmp_dir) }

    # A named controller-like class exposing what extraction introspects.
    # With no file under Rails.root, every resolvable source location points
    # at this spec file — outside the app — so the extractor must reject it.
    def named_controller_class(name)
      klass = Class.new
      klass.define_singleton_method(:name) { name }
      klass.define_singleton_method(:action_methods) { Set.new }
      klass.define_singleton_method(:_process_action_callbacks) { [] }
      klass.define_singleton_method(:ancestors) { [] }
      klass.define_singleton_method(:included_modules) { [] }
      klass.define_singleton_method(:instance_methods) { |_inherit = true| [] }
      klass
    end

    # An app-defined controller: named, with a source file at the
    # convention path under Rails.root.
    def app_controller_class(name)
      relative = "app/controllers/#{name.underscore}.rb"
      full_path = File.join(tmp_dir, relative)
      FileUtils.mkdir_p(File.dirname(full_path))
      File.write(full_path, "class #{name} < ActionController::Base\nend\n")
      named_controller_class(name)
    end

    def stub_action_controller_base(*descendant_classes)
      base = Class.new
      base.define_singleton_method(:descendants) { descendant_classes }
      stub_const('ActionController::Base', base)
    end

    def stub_action_controller_api(*descendant_classes)
      api = Class.new
      api.define_singleton_method(:descendants) { descendant_classes }
      stub_const('ActionController::API', api)
    end

    it 'includes ApplicationController itself, which Class#descendants excludes' do
      application_controller = app_controller_class('ApplicationController')
      posts = app_controller_class('PostsController')
      stub_action_controller_base(application_controller, posts)
      # Mirror the real hierarchy: the old discovery read this constant's
      # descendants, which never include the receiver.
      stub_const('ApplicationController', application_controller)
      application_controller.define_singleton_method(:descendants) { [posts] }

      expect(extractor.discoverable_classes).to contain_exactly(application_controller, posts)
    end

    it 'includes controllers inheriting directly from ActionController::Base' do
      application_controller = app_controller_class('ApplicationController')
      legacy = app_controller_class('LegacyController')
      stub_action_controller_base(application_controller, legacy)
      stub_const('ApplicationController', application_controller)
      application_controller.define_singleton_method(:descendants) { [] }

      expect(extractor.discoverable_classes).to include(legacy)
    end

    it 'excludes framework-internal controllers whose source lives outside the app' do
      posts = app_controller_class('PostsController')
      framework = named_controller_class('Rails::InfoController')
      stub_action_controller_base(posts, framework)

      expect(extractor.discoverable_classes).to contain_exactly(posts)
    end

    it 'excludes anonymous controller classes' do
      posts = app_controller_class('PostsController')
      anonymous = Class.new
      stub_action_controller_base(posts, anonymous)

      expect(extractor.discoverable_classes).to contain_exactly(posts)
    end

    it 'finds API controllers without NameError when the host has no ApplicationController' do
      api_controller = app_controller_class('Api::BaseController')
      stub_action_controller_api(api_controller)

      expect(extractor.discoverable_classes).to contain_exactly(api_controller)
    end

    it 'returns an empty array when neither ActionController base is defined' do
      hide_const('ActionController') if defined?(ActionController)

      expect(extractor.discoverable_classes).to eq([])
    end

    it 'deduplicates classes discovered through both bases' do
      shared = app_controller_class('SharedController')
      stub_action_controller_base(shared)
      stub_action_controller_api(shared)

      expect(extractor.discoverable_classes).to contain_exactly(shared)
    end

    it 'discovers exactly the set extract_controller accepts (reconciliation stability)' do
      app_controller = app_controller_class('PagesController')
      framework = named_controller_class('Rails::WelcomeController')
      anonymous = Class.new
      universe = [app_controller, framework, anonymous]
      stub_action_controller_base(*universe)

      accepted = universe.select { |klass| extractor.send(:extract_controller, klass) }

      expect(accepted).to contain_exactly(app_controller)
      expect(extractor.discoverable_classes).to match_array(accepted)
    end
  end
end
