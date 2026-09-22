# frozen_string_literal: true

require_relative 'puma_child'

module Woods
  module Watch
    # Optional Puma master-process integration. Requiring Woods itself never
    # loads Puma or starts a watcher; only `plugin :woods` installs these hooks.
    class PumaAdapter
      SUPPORTED_MAJORS = [6, 7, 8].freeze
      FALLBACK = 'Run bin/woods-watch through your development process manager instead.'

      # @param launcher [Puma::Launcher] configured master launcher
      # @param puma_version [String] loaded Puma version
      # @param platform [String] Ruby platform used for supported-mode checks
      def initialize(launcher, puma_version: ::Puma::Const::PUMA_VERSION, platform: RUBY_PLATFORM)
        @launcher = launcher
        @puma_version = puma_version
        @platform = platform
        @master_pid = Process.pid
        # Puma has already chdir'd before plugin start. Expanding its raw
        # relative `directory` option here would apply that directory twice.
        @root = Dir.pwd
        @started = false
        @installed = false
      end

      # Register master-only lifecycle callbacks without starting extraction.
      # @return [void]
      def install
        return if @installed

        @installed = true
        unless supported?
          log("Puma #{@puma_version} on #{@platform} is unsupported by the Woods plugin. #{FALLBACK}")
          return
        end

        hook(:after_booted, :on_booted) { start }
        hook(:before_restart, :on_restart) { stop }
        hook(:after_stopped, :on_stopped) { stop }
      end

      # Start at most once after Puma has finalized its environment and booted.
      # @return [void]
      def start
        return unless Process.pid == @master_pid
        return if @started || @launcher.options[:environment].to_s != 'development'

        @started = true
        unless File.file?(File.join(@root, 'bin/woods-watch'))
          log('Missing bin/woods-watch; run bin/rails generate woods:watch --mode=puma. ' \
              'Automatic maintenance is inactive.')
          return
        end

        @child = PumaChild.new(root: @root, environment: 'development', logger: @launcher.log_writer)
        pid = @child.start
        log("Started launcher #{pid}; index readiness is reported separately by woods-watch.")
      rescue SystemCallError => e
        log("Could not start launcher (#{e.class}); automatic maintenance is inactive. #{FALLBACK}")
      end

      # Stop only the launcher owned by this master process.
      # @return [void]
      def stop
        @child&.stop if Process.pid == @master_pid
      end

      private

      def supported?
        SUPPORTED_MAJORS.include?(@puma_version.to_s.split('.').first.to_i) &&
          Process.respond_to?(:fork) && !@platform.match?(/mswin|mingw|cygwin|java/)
      end

      def hook(current, legacy, &block)
        events = @launcher.events
        events.public_send(events.respond_to?(current) ? current : legacy, &block)
      end

      def log(message)
        @launcher.log_writer.log("[woods-watch] #{message}")
      end
    end
  end
end
