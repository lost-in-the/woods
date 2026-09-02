# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# End-to-end coverage for exe/woods-console's boot sequence, run in a real
# child Ruby process (not `bundle exec rspec` in-process) so the script's
# top-level `require`/`load` order and its interaction with a Rails-shaped
# environment are exercised exactly as they run in production — the same
# reasoning as spec/load_order_spec.rb, applied to a script instead of a
# library require.
#
# A full Rails boot isn't available in the default (non-:booted_app) spec
# run, so each case boots the real exe/woods-console under a minimal fake
# `Rails`/`ActiveRecord::Base` and a `StdioTransport` stub that returns
# immediately instead of blocking on stdin. This keeps the two boot-time
# robustness checks (eager_load! rescue, empty console_blocked_tables
# warning) covered without requiring a booted Rails host.
RSpec.describe 'exe/woods-console boot sequence' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:fake_boot_script) { File.join(@tmpdir, 'fake_boot.rb') }

  around do |example|
    Dir.mktmpdir('woods-console-boot') do |tmpdir|
      @tmpdir = tmpdir
      File.write(fake_boot_script, fake_boot_source)
      example.run
    end
  end

  # Fakes just enough of a Rails host to reach exe/woods-console's own
  # logic: a `Rails.application` that responds to `eager_load!` (raising a
  # NameError on request, mirroring a real app/graphql/ load failure), an
  # empty `ActiveRecord::Base.descendants` (skips the per-model registry
  # loops entirely — nothing under test there), and a `StdioTransport` that
  # returns immediately instead of blocking on stdin.
  def fake_boot_source
    <<~RUBY
      $LOAD_PATH.unshift(File.expand_path('lib', Dir.pwd))
      require 'mcp'
      require 'woods'

      module Rails
        RailsEnvironment = Struct.new(:name) do
          def production?
            name == 'production'
          end
        end

        class FakeApplication
          def eager_load!
            raise NameError, 'uninitialized constant Foo (fake)' if ENV['FAKE_EAGER_LOAD_RAISES']
          end
        end

        def self.application
          @application ||= FakeApplication.new
        end

        def self.env
          RailsEnvironment.new(ENV.fetch('FAKE_RAILS_ENV', 'test'))
        end
      end

      module ActiveRecord
        class FakePool
          def with_connection
            yield(nil)
          end
        end

        class Base
          def self.descendants
            []
          end

          # Both accessors announce themselves so a spec can prove which one
          # the boot script reaches for.
          def self.connection
            warn '[fake-boot] ActiveRecord::Base.connection'
            nil
          end

          def self.connection_pool
            warn '[fake-boot] ActiveRecord::Base.connection_pool'
            FakePool.new
          end
        end
      end

      require 'woods/console/server'

      class MCP::Server::Transports::StdioTransport
        def initialize(_server); end

        def open
          warn '[fake-boot] transport opened, exiting immediately'
        end
      end

      Woods.configuration.console_mcp_enabled = true
      Woods.configuration.console_credential_defense_enabled = false
      Woods.configuration.console_blocked_tables = [] if ENV['FAKE_BLOCKED_TABLES_EMPTY']

      $woods_protocol_out = $stdout.dup
      load File.expand_path('exe/woods-console', Dir.pwd)
    RUBY
  end

  # Open3's env hash is merged on top of the inherited environment (not a
  # replacement), so PATH/BUNDLE_PATH/BUNDLE_GEMFILE from whatever shell is
  # running the suite carry through automatically.
  def run_fake_boot(env = {})
    Open3.capture3(env, 'bundle', 'exec', 'ruby', '-Ilib', fake_boot_script, chdir: root, stdin_data: '')
  end

  it 'boots cleanly when eager_load! succeeds and blocked tables are configured' do
    _stdout, stderr, status = run_fake_boot

    expect(status).to be_success
    expect(stderr).not_to include('eager_load!')
    expect(stderr).not_to include('Layer 1 (table gate) is INACTIVE')
  end

  it 'warns and continues instead of crashing when eager_load! raises a NameError' do
    _stdout, stderr, status = run_fake_boot('FAKE_EAGER_LOAD_RAISES' => '1')

    expect(status).to be_success
    expect(stderr).to include('[Woods Console] eager_load! hit NameError')
    expect(stderr).to include('Continuing with a possibly incomplete model registry')
    # The server still boots and opens the transport — it isn't a crash.
    expect(stderr).to include('transport opened')
  end

  it 'warns when console_blocked_tables is empty outside production' do
    _stdout, stderr, status = run_fake_boot('FAKE_BLOCKED_TABLES_EMPTY' => '1')

    expect(status).to be_success
    expect(stderr).to include('console_blocked_tables is empty')
    expect(stderr).to include('Layer 1 (table gate) is INACTIVE')
  end

  # L10. `SafeContext.new(connection: ActiveRecord::Base.connection)` captured
  # one connection for the process lifetime: after a failover or a
  # `wait_timeout` recycle every tool call failed on a stale connection until
  # restart. The HTTP path already leases per request
  # (`RackMiddleware#build_embedded_server` passes `pool:`); stdio predates
  # that fix. Boot must reach for the pool, never the bare connection.
  it 'builds SafeContext from the connection pool, not a pinned connection' do
    _stdout, stderr, status = run_fake_boot

    expect(status).to be_success
    expect(stderr).to include('[fake-boot] ActiveRecord::Base.connection_pool')
    expect(stderr.lines.grep(/ActiveRecord::Base\.connection$/)).to be_empty
  end

  it 'raises instead of booting when console_blocked_tables is empty in production' do
    _stdout, stderr, status = run_fake_boot(
      'FAKE_BLOCKED_TABLES_EMPTY' => '1', 'FAKE_RAILS_ENV' => 'production'
    )

    expect(status).not_to be_success
    expect(stderr).to include('Woods::ConfigurationError')
    expect(stderr).to include('console_blocked_tables is empty')
  end
end
