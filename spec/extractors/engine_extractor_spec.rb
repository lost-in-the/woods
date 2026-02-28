# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/extracted_unit'
require 'codebase_index/extractors/engine_extractor'

RSpec.describe CodebaseIndex::Extractors::EngineExtractor do
  subject(:extractor) { described_class.new }

  describe '#extract_all' do
    context 'when Rails::Engine is not defined' do
      before do
        hide_const('Rails::Engine') if defined?(Rails::Engine)
      end

      it 'returns an empty array' do
        expect(extractor.extract_all).to eq([])
      end
    end

    context 'when Rails::Engine has no subclasses' do
      before do
        stub_const('Rails::Engine', engine_base_class)
        allow(Rails::Engine).to receive(:subclasses).and_return([])
        stub_rails_application
      end

      it 'returns an empty array' do
        expect(extractor.extract_all).to eq([])
      end
    end

    context 'with engine subclasses' do
      let(:engine_class) { build_mock_engine('Devise::Engine', 'devise') }
      let(:another_engine) { build_mock_engine('Sidekiq::Web::Engine', 'sidekiq-web') }

      before do
        stub_const('Rails::Engine', engine_base_class)
        allow(Rails::Engine).to receive(:subclasses).and_return([engine_class, another_engine])
        stub_rails_application(engines: [engine_class, another_engine])
      end

      it 'returns one unit per engine subclass' do
        units = extractor.extract_all
        expect(units.size).to eq(2)
      end

      it 'produces units with type :engine' do
        units = extractor.extract_all
        expect(units.map(&:type)).to all(eq(:engine))
      end

      it 'uses engine class name as identifier' do
        units = extractor.extract_all
        identifiers = units.map(&:identifier)
        expect(identifiers).to contain_exactly('Devise::Engine', 'Sidekiq::Web::Engine')
      end

      it 'sets namespace from engine class name' do
        units = extractor.extract_all
        devise_unit = units.find { |u| u.identifier == 'Devise::Engine' }
        expect(devise_unit.namespace).to eq('Devise')
      end

      it 'sets file_path to nil for runtime-only extractor' do
        units = extractor.extract_all
        expect(units.map(&:file_path)).to all(be_nil)
      end

      it 'includes engine_name in metadata' do
        units = extractor.extract_all
        devise_unit = units.find { |u| u.identifier == 'Devise::Engine' }
        expect(devise_unit.metadata[:engine_name]).to eq('devise')
      end

      it 'includes root_path in metadata' do
        units = extractor.extract_all
        devise_unit = units.find { |u| u.identifier == 'Devise::Engine' }
        expect(devise_unit.metadata[:root_path]).to eq('/gems/devise-4.9.0')
      end

      it 'includes route_count in metadata' do
        units = extractor.extract_all
        devise_unit = units.find { |u| u.identifier == 'Devise::Engine' }
        expect(devise_unit.metadata[:route_count]).to eq(3)
      end

      it 'includes isolate_namespace in metadata' do
        units = extractor.extract_all
        devise_unit = units.find { |u| u.identifier == 'Devise::Engine' }
        expect(devise_unit.metadata[:isolate_namespace]).to eq(true)
      end
    end

    context 'with engine_source tagging' do
      let(:framework_engine) { build_mock_engine('ActionCable::Engine', 'action_cable') }
      let(:app_engine) { build_mock_engine('MyApp::Engine', 'my_app', root_path: '/rails/app/engines/my_app') }

      before do
        stub_const('Rails::Engine', engine_base_class)
        allow(Rails::Engine).to receive(:subclasses).and_return([framework_engine, app_engine])
        stub_rails_application(engines: [framework_engine, app_engine])
      end

      it 'tags framework engines as :framework' do
        units = extractor.extract_all
        fw_unit = units.find { |u| u.identifier == 'ActionCable::Engine' }
        expect(fw_unit.metadata[:engine_source]).to eq(:framework)
      end

      it 'tags application engines as :application' do
        units = extractor.extract_all
        app_unit = units.find { |u| u.identifier == 'MyApp::Engine' }
        expect(app_unit.metadata[:engine_source]).to eq(:application)
      end
    end

    context 'with mounted engines' do
      let(:engine_class) { build_mock_engine('Devise::Engine', 'devise') }

      before do
        stub_const('Rails::Engine', engine_base_class)
        allow(Rails::Engine).to receive(:subclasses).and_return([engine_class])
        stub_rails_application(
          engines: [engine_class],
          mounts: { engine_class => '/auth' }
        )
      end

      it 'includes mounted_path in metadata' do
        units = extractor.extract_all
        devise_unit = units.first
        expect(devise_unit.metadata[:mounted_path]).to eq('/auth')
      end
    end

    context 'with unmounted engines' do
      let(:engine_class) { build_mock_engine('MyGem::Engine', 'my_gem') }

      before do
        stub_const('Rails::Engine', engine_base_class)
        allow(Rails::Engine).to receive(:subclasses).and_return([engine_class])
        stub_rails_application(engines: [engine_class], mounts: {})
      end

      it 'sets mounted_path to nil' do
        units = extractor.extract_all
        expect(units.first.metadata[:mounted_path]).to be_nil
      end
    end

    context 'with engine route controllers' do
      let(:engine_class) do
        build_mock_engine('Devise::Engine', 'devise', controllers: %w[sessions registrations])
      end

      before do
        stub_const('Rails::Engine', engine_base_class)
        allow(Rails::Engine).to receive(:subclasses).and_return([engine_class])
        stub_rails_application(engines: [engine_class])
      end

      it 'includes controller dependencies' do
        units = extractor.extract_all
        deps = units.first.dependencies
        controller_deps = deps.select { |d| d[:type] == :controller }
        targets = controller_deps.map { |d| d[:target] }
        expect(targets).to contain_exactly('SessionsController', 'RegistrationsController')
      end

      it 'sets :via to :engine_route on controller dependencies' do
        units = extractor.extract_all
        deps = units.first.dependencies
        controller_deps = deps.select { |d| d[:type] == :controller }
        expect(controller_deps.map { |d| d[:via] }).to all(eq(:engine_route))
      end
    end

    context 'when an engine raises an error' do
      let(:good_engine) { build_mock_engine('Good::Engine', 'good') }
      let(:bad_engine) do
        engine = build_mock_engine('Bad::Engine', 'bad')
        allow(engine).to receive(:engine_name).and_raise(StandardError, 'boom')
        engine
      end

      before do
        stub_const('Rails::Engine', engine_base_class)
        allow(Rails::Engine).to receive(:subclasses).and_return([bad_engine, good_engine])
        stub_rails_application(engines: [bad_engine, good_engine])
      end

      it 'skips the failing engine and extracts the rest' do
        without_partial_double_verification do
          logger = double('logger', error: nil, info: nil, warn: nil, debug: nil)
          allow(Rails).to receive(:logger).and_return(logger)
          units = extractor.extract_all
          expect(units.size).to eq(1)
          expect(units.first.identifier).to eq('Good::Engine')
        end
      end

      it 'logs the error' do
        without_partial_double_verification do
          logger = double('logger', error: nil, info: nil, warn: nil, debug: nil)
          allow(Rails).to receive(:logger).and_return(logger)
          extractor.extract_all
          expect(logger).to have_received(:error).with(/Failed to extract engine/)
        end
      end
    end

    context 'when Rails.application is not available' do
      before do
        stub_const('Rails::Engine', engine_base_class)
        allow(Rails).to receive(:respond_to?).and_call_original
        allow(Rails).to receive(:respond_to?).with(:application).and_return(false)
        allow(Rails).to receive(:respond_to?).with(:application, anything).and_return(false)
      end

      it 'returns an empty array' do
        expect(extractor.extract_all).to eq([])
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────

  # Build a base class that has .subclasses defined (Ruby 3.0 compat).
  # Class#subclasses was added in Ruby 3.1; on 3.0 RSpec's verify_partial_doubles
  # rejects `allow(klass).to receive(:subclasses)` on a bare Class.
  def engine_base_class
    klass = Class.new
    klass.define_singleton_method(:subclasses) { [] } unless klass.respond_to?(:subclasses)
    klass
  end

  def build_mock_engine(name, engine_name, controllers: [], route_count: 3, root_path: nil)
    engine = double(name)
    allow(engine).to receive(:name).and_return(name)
    allow(engine).to receive(:engine_name).and_return(engine_name)

    root = double('root', to_s: root_path || "/gems/#{engine_name}-4.9.0")
    allow(engine).to receive(:root).and_return(root)

    stub_engine_routes(engine, controllers, route_count)
    allow(engine).to receive(:isolated?).and_return(true)

    engine
  end

  def stub_engine_routes(engine, controllers, route_count)
    route_objects = route_count.times.map do |i|
      route = double("route_#{i}")
      defaults = controllers.any? ? { controller: controllers[i % controllers.length], action: 'index' } : {}
      allow(route).to receive(:defaults).and_return(defaults)
      route
    end
    routes = double('routes')
    allow(routes).to receive(:routes).and_return(route_objects)
    allow(engine).to receive(:routes).and_return(routes)
  end

  def stub_rails_application(engines: [], mounts: nil)
    mounts ||= engines.to_h { |e| [e, nil] }
    mount_routes = build_mount_routes(mounts)

    app_routes = double('app_routes')
    allow(app_routes).to receive(:routes).and_return(mount_routes)

    application = double('application')
    allow(application).to receive(:routes).and_return(app_routes)

    stub_rails_respond_to(application)
  end

  def build_mount_routes(mounts)
    mounts.map do |engine, path|
      route = double('mount_route')
      allow(route).to receive(:app).and_return(engine)
      app_path = path ? double('path', spec: double(to_s: path)) : nil
      allow(route).to receive(:path).and_return(app_path)
      allow(route).to receive(:defaults).and_return({})
      route
    end
  end

  def stub_rails_respond_to(application)
    allow(Rails).to receive(:respond_to?).and_call_original
    allow(Rails).to receive(:respond_to?).with(:application).and_return(true)
    allow(Rails).to receive(:respond_to?).with(:application, anything).and_return(true)
    allow(Rails).to receive(:application).and_return(application)

    # framework_engine? needs Rails.root; extract_engine rescue needs Rails.logger
    # Rails module is created by stub_const — doesn't implement root/logger,
    # so we disable verification for these stubs.
    without_partial_double_verification do
      rails_root = double('root', to_s: '/rails/app')
      allow(Rails).to receive(:root).and_return(rails_root)
      allow(Rails).to receive(:logger).and_return(double('Logger', error: nil, warn: nil, info: nil, debug: nil))
    end
  end
end
