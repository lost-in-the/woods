# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/railtie_support'

# The railtie itself (Woods::Railtie < Rails::Railtie) cannot load without
# railties, and these unit specs run without a booted Rails app — that limit
# is deliberate (see CLAUDE.md). What CAN be covered here, and is:
#
#   * Woods::RailtieSupport — the after_initialize verification that
#     replaces the old boot-time flag checks (#183).
#   * A mirror of the 'woods.session_tracer' initializer body (kept in sync
#     with railtie.rb).
#
# The actual `app.middleware.use` wiring and initializer ordering are only
# observable in a booted host app (verified against Rails 8.1 for #183).
RSpec.describe 'Woods::Railtie support logic' do
  before do
    Woods.configuration = nil
    Woods::RailtieSupport.session_tracer_state = nil
  end

  after do
    Woods.configuration = nil
    Woods::RailtieSupport.session_tracer_state = nil
  end

  describe 'Woods::RailtieSupport.verify_session_tracer_configuration!' do
    before { allow(Woods::RailtieSupport).to receive(:warn) }

    context 'when the flag was set too late for the railtie to mount (state nil)' do
      before { Woods.configure { |c| c.session_tracer_enabled = true } }

      it 'warns with the config/application.rb remediation' do
        Woods::RailtieSupport.verify_session_tracer_configuration!

        expect(Woods::RailtieSupport).to have_received(:warn)
          .with(a_string_including('config/application.rb'))
      end
    end

    context 'when the middleware was mounted' do
      before do
        Woods.configure { |c| c.session_tracer_enabled = true }
        Woods::RailtieSupport.session_tracer_state = :mounted
      end

      it 'does not warn' do
        Woods::RailtieSupport.verify_session_tracer_configuration!
        expect(Woods::RailtieSupport).not_to have_received(:warn)
      end
    end

    context 'when the production guard skipped mounting (already warned at boot)' do
      before do
        Woods.configure { |c| c.session_tracer_enabled = true }
        Woods::RailtieSupport.session_tracer_state = :skipped_production
      end

      it 'does not warn again' do
        Woods::RailtieSupport.verify_session_tracer_configuration!
        expect(Woods::RailtieSupport).not_to have_received(:warn)
      end
    end

    context 'when the tracer is disabled' do
      it 'does not warn' do
        Woods::RailtieSupport.verify_session_tracer_configuration!
        expect(Woods::RailtieSupport).not_to have_received(:warn)
      end
    end
  end
end

# Mirror of the 'woods.session_tracer' initializer body — kept in sync with
# railtie.rb. The session tracer middleware requires a store at construction,
# so it stays conditionally mounted; the after_initialize warning covered
# above handles the too-late-flag case.
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
    Woods::RailtieSupport.session_tracer_state = nil
  end

  after do
    Woods.configuration = nil
    Woods::RailtieSupport.session_tracer_state = nil
  end

  # Run the initializer block directly (mirrors what Rails calls during boot)
  def run_initializer(config, rails_env:, logger: nil)
    # Simulate the block body — kept in sync with railtie.rb
    Woods::RailtieSupport.session_tracer_state = nil
    return unless config.session_tracer_enabled

    if rails_env == 'production' && !config.session_tracer_allow_production
      warn_production_guard(logger)
      Woods::RailtieSupport.session_tracer_state = :skipped_production
      return
    end

    require 'woods/session_tracer/middleware'

    app.middleware.use(
      Woods::SessionTracer::Middleware,
      store: config.session_store,
      session_id_proc: config.session_id_proc,
      exclude_paths: config.session_exclude_paths
    )
    Woods::RailtieSupport.session_tracer_state = :mounted
  end

  # Mirrors the production-guard warning branch in railtie.rb
  def warn_production_guard(logger)
    msg = '[Woods] session tracer disabled in production; ' \
          'set `session_tracer_allow_production = true` to opt in.'
    if logger
      logger.warn(msg)
    else
      warn msg
    end
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

    it 'records the skip so after_initialize does not re-warn' do
      logger = instance_double(Logger, warn: nil)
      run_initializer(Woods.configuration, rails_env: 'production', logger: logger)
      expect(Woods::RailtieSupport.session_tracer_state).to eq(:skipped_production)
    end

    it 'emits a warning to the provided logger' do
      logger = instance_double(Logger)
      expect(logger).to receive(:warn).with(a_string_including('session tracer disabled in production'))
      run_initializer(Woods.configuration, rails_env: 'production', logger: logger)
    end

    it 'emits the opt-in instruction in the warning' do
      logger = instance_double(Logger)
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

    it 'records the mount so after_initialize does not warn' do
      run_initializer(Woods.configuration, rails_env: 'development')
      expect(Woods::RailtieSupport.session_tracer_state).to eq(:mounted)
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
