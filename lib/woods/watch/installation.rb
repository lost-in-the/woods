# frozen_string_literal: true

require 'json'
require_relative '../agent_configuration/applier'
require_relative '../agent_configuration/plan'
require_relative 'installation/layout'
require_relative 'installation/options'
require_relative 'installation/planner'
require_relative 'installation/probe'
require_relative 'installation/recovery'

module Woods
  module Watch
    # Plans and applies portable, explicitly owned watcher startup configuration.
    class Installation
      Conflict = Woods::AgentConfiguration::Conflict

      # @param root [String] application directory
      # @param options [Hash] mode, operation, child/manager argv and preflight options
      def initialize(root:, **options)
        @options = Options.new(root: root, **options)
        @layout = Layout.new(@options.root, @options.procfile)
      end

      # Preview all edits without creating files or starting a watcher.
      # @return [Woods::AgentConfiguration::Plan]
      def plan
        @options.validate!
        Planner.new(layout: @layout, options: @options).call
      end

      # Apply a fresh or previously reviewed plan using conflict-checked writes.
      # @param reviewed_plan [Woods::AgentConfiguration::Plan, nil] optional preview
      # @return [String] applied or already_applied
      def apply(reviewed_plan = nil)
        selected = reviewed_plan || plan
        return 'already_applied' if selected.data.fetch('changes').empty?

        Woods::AgentConfiguration::Applier.new(layout: @layout).apply(selected)
      end

      # Explain which process must own this installation.
      # @return [String]
      def handoff
        @options.handoff
      end

      # Recover an interrupted transaction without booting the application.
      # @param pretend [Boolean] validate the journal without restoring files
      # @return [String] recovery outcome
      def recover(pretend: false)
        Recovery.new(root: @options.root).call(pretend: pretend)
      end
    end
  end
end
