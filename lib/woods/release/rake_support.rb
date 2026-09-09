# frozen_string_literal: true

require_relative '../release'

module Woods
  module Release
    # Keeps `lib/tasks/release.rake` a thin wrapper: argument handling, refusal
    # reporting, and blocking the publish tasks Bundler installs.
    module RakeSupport
      ROOT = File.expand_path('../../..', __dir__)

      # Owned by Woods::ReleaseV2::SurfaceInventory. Named here so the release
      # report can list it without loading the extraction stack.
      SURFACE_INVENTORY_PATH = '.Codex/release-v2/surface-inventory.json'

      module_function

      # Runs one transition and prints its report, turning any release refusal
      # into a clean abort rather than a backtrace.
      def run(task_name, version)
        abort %(usage: bin/rake "#{task_name}[2.0.0.beta1]") if version.nil? || version.to_s.strip.empty?

        puts yield(ROOT, version.to_s.strip).report
      rescue Woods::Release::Error => e
        abort "#{task_name} refused: #{e.message}"
      end

      # Replaces an already-defined task with an abort explaining the flow.
      #
      # The description is reattached deliberately: `Rake::Task#clear` drops it,
      # and a task missing from `rake -T` is one the next person rediscovers by
      # running it.
      def block_task(name, description:, message:)
        return unless Rake::Task.task_defined?(name)

        Rake::Task[name].clear
        Rake::Task.define_task(name) { abort "#{name} is blocked: #{message}" }
        Rake::Task[name].add_description(description)
      end
    end
  end
end
