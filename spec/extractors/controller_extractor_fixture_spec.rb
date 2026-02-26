# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/extractors/controller_extractor'

RSpec.describe CodebaseIndex::Extractors::ControllerExtractor, 'fixture specs' do
  # ── Helper to build a fake controller class with source file ──────────

  let(:tmp_dir) { Dir.mktmpdir }
  let(:rails_root) { Pathname.new(tmp_dir) }
  let(:logger) { double('Logger', error: nil, warn: nil, debug: nil, info: nil) }

  after { FileUtils.rm_rf(tmp_dir) }

  def create_file(relative_path, content)
    full_path = File.join(tmp_dir, relative_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
    full_path
  end

  # Build a mock controller class with configurable actions and callbacks
  def build_controller(name, parent:, actions: [], callbacks: [], source_file: nil)
    klass = Class.new
    klass.define_singleton_method(:name) { name }
    klass.define_singleton_method(:ancestors) { [klass, parent] }
    klass.define_singleton_method(:action_methods) { Set.new(actions.map(&:to_s)) }
    klass.define_singleton_method(:_process_action_callbacks) { callbacks }
    klass.define_singleton_method(:included_modules) { [] }
    klass.define_singleton_method(:descendants) { [] }

    # Define action methods so instance_method(:action_name) works
    actions.each { |a| klass.define_method(a.to_sym) { nil } }
    stub_instance_methods(klass, actions, source_file)

    klass
  end

  def stub_instance_methods(klass, actions, source_file)
    if source_file
      klass.define_method(:__fixture_action) { nil }
      methods_list = actions.map(&:to_sym) + [:__fixture_action]
      allow(klass).to receive(:instance_methods).with(false).and_return(methods_list)
      allow(klass.instance_method(:__fixture_action)).to receive(:source_location).and_return([source_file, 1])
    else
      methods_list = actions.map(&:to_sym)
      klass.define_singleton_method(:instance_methods) { |_inherit| methods_list }
    end
  end

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

  let(:base_controller) { Class.new }
  let(:app_controller) { Class.new(base_controller) }

  let(:extractor) do
    routes_double = double('Routes', routes: [])
    app_double = double('Application', routes: routes_double)
    stub_const('Rails', double('Rails', root: rails_root, application: app_double, logger: logger))
    stub_const('ActionController::Base', base_controller)
    stub_const('ActionController::API', base_controller)
    stub_const('ApplicationController', app_controller)
    described_class.new
  end

  # ── API Controller with Multiple Actions ──────────────────────────────

  describe 'API controller with multiple actions' do
    it 'extracts actions, filters, and response formats' do
      source_path = create_file('app/controllers/api/v1/users_controller.rb', <<~RUBY)
        class Api::V1::UsersController < ApplicationController
          before_action :authenticate_token!
          before_action :set_user, only: [:show, :update, :destroy]

          def index
            render json: User.all
          end

          def show
            render json: @user
          end

          def create
            user = User.new(user_params)
            if user.save
              render json: user, status: :created
            else
              render json: user.errors, status: :unprocessable_entity
            end
          end

          def update
            if @user.update(user_params)
              render json: @user
            else
              render json: @user.errors, status: :unprocessable_entity
            end
          end

          def destroy
            @user.destroy
            head :no_content
          end

          private

          def set_user
            @user = User.find(params[:id])
          end

          def user_params
            params.require(:user).permit(:name, :email, :role)
          end
        end
      RUBY

      only_filter = build_action_filter(%w[show update destroy])
      callbacks = [
        build_callback(kind: :before, filter: :authenticate_token!),
        build_callback(kind: :before, filter: :set_user, if_conditions: [only_filter])
      ]

      controller = build_controller(
        'Api::V1::UsersController',
        parent: app_controller,
        actions: %w[index show create update destroy],
        callbacks: callbacks,
        source_file: source_path
      )

      unit = extractor.send(:extract_controller, controller)

      expect(unit).not_to be_nil
      expect(unit.type).to eq(:controller)
      expect(unit.identifier).to eq('Api::V1::UsersController')
      expect(unit.metadata[:actions]).to match_array(%w[index show create update destroy])
      expect(unit.metadata[:action_count]).to eq(5)
      expect(unit.metadata[:filter_count]).to eq(2)
      expect(unit.metadata[:responds_to]).to include(:json)
      expect(unit.metadata[:permitted_params]).to have_key('user_params')
    end
  end

  # ── Empty Controller ──────────────────────────────────────────────────

  describe 'empty controller' do
    it 'extracts a controller with no actions' do
      source_path = create_file('app/controllers/health_controller.rb', <<~RUBY)
        class HealthController < ApplicationController
        end
      RUBY

      controller = build_controller(
        'HealthController',
        parent: app_controller,
        actions: [],
        callbacks: [],
        source_file: source_path
      )

      unit = extractor.send(:extract_controller, controller)

      expect(unit).not_to be_nil
      expect(unit.identifier).to eq('HealthController')
      expect(unit.metadata[:actions]).to be_empty
      expect(unit.metadata[:action_count]).to eq(0)
    end
  end

  # ── Namespaced Controller ─────────────────────────────────────────────

  describe 'namespaced controller (Api::V1::UsersController)' do
    it 'extracts namespace correctly' do
      source_path = create_file('app/controllers/api/v1/posts_controller.rb', <<~RUBY)
        class Api::V1::PostsController < ApplicationController
          def index
            render json: Post.all
          end
        end
      RUBY

      controller = build_controller(
        'Api::V1::PostsController',
        parent: app_controller,
        actions: %w[index],
        callbacks: [],
        source_file: source_path
      )

      unit = extractor.send(:extract_controller, controller)

      expect(unit).not_to be_nil
      expect(unit.namespace).to eq('Api::V1')
    end
  end

  # ── Controller with before_action Callbacks ───────────────────────────

  describe 'controller with before_action callbacks' do
    it 'extracts filter chain with only/except' do
      source_path = create_file('app/controllers/admin/dashboard_controller.rb', <<~RUBY)
        class Admin::DashboardController < ApplicationController
          before_action :require_admin
          before_action :set_timezone, only: [:show]

          def show
            render json: { status: 'ok' }
          end

          def stats
            render json: Stats.current
          end
        end
      RUBY

      only_filter = build_action_filter(%w[show])
      callbacks = [
        build_callback(kind: :before, filter: :require_admin),
        build_callback(kind: :before, filter: :set_timezone, if_conditions: [only_filter])
      ]

      controller = build_controller(
        'Admin::DashboardController',
        parent: app_controller,
        actions: %w[show stats],
        callbacks: callbacks,
        source_file: source_path
      )

      unit = extractor.send(:extract_controller, controller)

      filters = unit.metadata[:filters]
      expect(filters.size).to eq(2)
      expect(filters[0][:filter]).to eq(:require_admin)
      expect(filters[0]).not_to have_key(:only)
      expect(filters[1][:filter]).to eq(:set_timezone)
      expect(filters[1][:only]).to eq(%w[show])
    end
  end

  # ── Controller Source Annotation ──────────────────────────────────────

  describe 'source annotation' do
    it 'includes filter chain comment in composite source' do
      source_path = create_file('app/controllers/simple_controller.rb', <<~RUBY)
        class SimpleController < ApplicationController
          def index
            render json: []
          end
        end
      RUBY

      callbacks = [
        build_callback(kind: :before, filter: :set_locale)
      ]

      controller = build_controller(
        'SimpleController',
        parent: app_controller,
        actions: %w[index],
        callbacks: callbacks,
        source_file: source_path
      )

      unit = extractor.send(:extract_controller, controller)

      expect(unit.source_code).to include('Filter Chain')
      expect(unit.source_code).to include(':set_locale')
    end
  end

  # ── Controller with Turbo Stream Response ─────────────────────────────

  describe 'controller with turbo_stream response format' do
    it 'detects turbo_stream format' do
      source_path = create_file('app/controllers/comments_controller.rb', <<~RUBY)
        class CommentsController < ApplicationController
          def create
            @comment = Comment.create!(comment_params)
            respond_to do |format|
              format.turbo_stream
              format.html { redirect_to @comment.post }
            end
          end
        end
      RUBY

      controller = build_controller(
        'CommentsController',
        parent: app_controller,
        actions: %w[create],
        callbacks: [],
        source_file: source_path
      )

      unit = extractor.send(:extract_controller, controller)

      expect(unit.metadata[:responds_to]).to include(:turbo_stream)
      expect(unit.metadata[:responds_to]).to include(:html)
    end
  end

  # ── Controller with Component Renders ─────────────────────────────────

  describe 'controller dependency extraction' do
    it 'detects Phlex/ViewComponent render dependencies' do
      source_path = create_file('app/controllers/pages_controller.rb', <<~RUBY)
        class PagesController < ApplicationController
          def show
            render PageComponent.new(page: @page)
          end
        end
      RUBY

      controller = build_controller(
        'PagesController',
        parent: app_controller,
        actions: %w[show],
        callbacks: [],
        source_file: source_path
      )

      unit = extractor.send(:extract_controller, controller)

      component_deps = unit.dependencies.select { |d| d[:type] == :component }
      expect(component_deps.map { |d| d[:target] }).to include('PageComponent')
    end
  end
end
