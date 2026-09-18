# frozen_string_literal: true

require 'optparse'

module Woods
  module AgentConfiguration
    module CLIOptions
      def self.build(options)
        OptionParser.new do |parser|
          parser.banner = <<~USAGE
            Usage: woods-agent-config setup|update|remove --client claude --scope project|user --plan FILE [options]
                   woods-agent-config apply|show FILE --client claude --scope project|user [--root ROOT]
                   woods-agent-config recover --client claude --scope project|user [--root ROOT]
            Setup/update/remove create a private plan without changing managed configuration.
            Apply consumes that exact plan. Only Index MCP is configured; client trust remains separate.
          USAGE
          { client: '--client NAME', scope: '--scope SCOPE', root: '--root DIRECTORY',
            plan: '--plan FILE', name: '--name NAME', index: '--index PATH', mode: '--mode MODE',
            service: '--service NAME', container_root: '--container-root PATH' }.each do |key, option|
            parser.on(option) { |value| options[key] = value }
          end
          parser.on('--instructions LIST', Array) { |value| options[:instructions] = value }
          parser.on('--diff') { options[:diff] = true }
          parser.on('-h', '--help') { options[:help] = true }
        end
      end
    end
  end
end
