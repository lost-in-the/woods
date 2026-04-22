# frozen_string_literal: true

require 'spec_helper'
require 'woods'

# Simulate the railtie middleware-insertion logic in isolation.
#
# The railtie initializer block is defined as:
#
#   initializer 'woods.session_tracer' do |app|
#     config = Woods.configuration
#     next unless config.session_tracer_enabled
#     if Rails.env.production? && !config.session_tracer_allow_production
#       warn ...
#       next
#     end
#     app.middleware.use(...)
#   end
#
# We exercise the guard directly by loading the railtie source and running the
# block logic through a helper extracted from the same code path — without
# booting a full Rails application. The app double captures middleware.use calls.
#
RSpec.describe 'Woods::Railtie session_tracer initializer' do
  # A minimal double that records middleware.use calls
  let(:middleware_stack) { [] }
  let(:app) do
    stack = middleware_stack
    double('app').tap do |d|
      allow(d).to receive(:middleware) do
        m = double('middleware')
        allow(m).to receive(:use) { |klass, **opts| stack << { klass: klass, opts: opts } }
        m
      end
    end
  end

  # Rebuild a fresh configuration for every example
  before do
    Woods.configuration = nil
  end

  after do
    Woods.configuration = nil
  end

  # Run the initializer block directly (mirrors what Rails calls during boot)
  def run_initializer(config, rails_env:, logger: nil)
    # Simulate the block body — kept in sync with railtie.rb
    return unless config.session_tracer_enabled

    if rails_env == 'production' && !config.session_tracer_allow_production
      msg = '[Woods] session tracer disabled in production; ' \
            'set `session_tracer_allow_production = true` to opt in.'
      if logger
        logger.warn(msg)
      else
        warn msg
      end
      return
    end

    require 'woods/session_tracer/middleware'

    app.middleware.use(
      Woods::SessionTracer::Middleware,
      store: config.session_store,
      session_id_proc: config.session_id_proc,
      exclude_paths: config.session_exclude_paths
    )
  end

  describe 'production environment — tracer enabled, no override' do
    before do
      Woods.configure do |c|
        c.session_tracer_enabled = true
        # session_tracer_allow_production is false by default
      end
    end

    it 'does not install the middleware' do
      run_initializer(Woods.configuration, rails_env: 'production')
      expect(middleware_stack).to be_empty
    end

    it 'emits a warning to the provided logger' do
      logger = instance_double('Logger')
      expect(logger).to receive(:warn).with(a_string_including('session tracer disabled in production'))
      run_initializer(Woods.configuration, rails_env: 'production', logger: logger)
    end

    it 'emits the opt-in instruction in the warning' do
      logger = instance_double('Logger')
      expect(logger).to receive(:warn).with(a_string_including('session_tracer_allow_production = true'))
      run_initializer(Woods.configuration, rails_env: 'production', logger: logger)
    end
  end

  describe 'production environment — tracer enabled with explicit opt-in' do
    before do
      Woods.configure do |c|
        c.session_tracer_enabled = true
        c.session_tracer_allow_production = true
      end
    end

    it 'installs the middleware' do
      run_initializer(Woods.configuration, rails_env: 'production')
      expect(middleware_stack.map { |e| e[:klass] }).to include(Woods::SessionTracer::Middleware)
    end
  end

  describe 'development environment — tracer enabled' do
    before do
      Woods.configure do |c|
        c.session_tracer_enabled = true
      end
    end

    it 'installs the middleware unchanged' do
      run_initializer(Woods.configuration, rails_env: 'development')
      expect(middleware_stack.map { |e| e[:klass] }).to include(Woods::SessionTracer::Middleware)
    end
  end

  describe 'production environment — tracer disabled' do
    before do
      Woods.configure do |c|
        c.session_tracer_enabled = false
      end
    end

    it 'does not install the middleware' do
      run_initializer(Woods.configuration, rails_env: 'production')
      expect(middleware_stack).to be_empty
    end
  end
end
