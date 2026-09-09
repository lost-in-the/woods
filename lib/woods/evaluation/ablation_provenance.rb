# frozen_string_literal: true

require 'json'

module Woods
  module Evaluation
    # Per-trial provenance (a binding ruling): the exact agent command run,
    # the model the agent reported (when the JSON payload names one), the
    # MCP wiring in effect, the Woods generation on disk in the checkout,
    # and the baseline SHA the checkout came from (#280).
    AblationProvenance = Struct.new(:agent_command, :model, :config, :woods_generation, :baseline_sha,
                                    keyword_init: true) do
      # @return [AblationProvenance]
      def self.build(agent_command:, chdir:, baseline_sha:)
        new(agent_command: agent_command, model: nil, config: mcp_config_of(agent_command),
            woods_generation: woods_generation_at(chdir), baseline_sha: baseline_sha)
      end

      def self.mcp_config_of(command)
        return 'strict' if command.include?('--strict-mcp-config')

        match = command.match(/--mcp-config[= ](\S+)/)
        match && match[1]
      end

      def self.woods_generation_at(chdir)
        generation_file = File.join(chdir, 'tmp', 'woods', 'generation.json')
        return nil unless File.exist?(generation_file)

        JSON.parse(File.read(generation_file))['number']
      rescue StandardError
        nil
      end

      private_class_method :mcp_config_of, :woods_generation_at
    end
  end
end
