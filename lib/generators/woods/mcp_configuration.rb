# frozen_string_literal: true

require 'json'
require 'woods/mcp/client_entry'

module Woods
  module Generators
    # The Index Server entry the install generator prints or adds to an MCP
    # client's `.mcp.json` ({Woods::MCP::ClientEntry}, shared with
    # `woods-agent-config`), and the rules for adding it to an existing file.
    module McpConfiguration
      # A Compose service name: what `docker compose exec` takes, and safe to
      # place in the shell command the container entry runs.
      SERVICE_NAME = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/

      # A file `woods-agent-config` writes beside a `.mcp.json` it manages.
      AGENT_CONFIG_RECEIPT = '.woods-agent-config.json'

      module_function

      # @param service [String, nil] the Compose service; nil for a host launch
      # @return [Hash] the entry for an application at its checkout root with
      #   its index at `tmp/woods` ({Woods::MCP::ClientEntry.checkout})
      def entry(service: nil)
        Woods::MCP::ClientEntry.checkout(service: service)
      end

      # @param entry [Hash]
      # @return [String]
      def snippet(entry)
        JSON.pretty_generate('mcpServers' => { 'woods' => entry })
      end

      # @param root [String] the application root
      # @param path [String] its `.mcp.json`
      # @param entry [Hash]
      # @return [String, Symbol, nil] why the file is left alone, `:absent`
      #   to create it, `:identical`, or nil to add the entry
      def skip_reason(root, path, entry)
        if File.exist?(File.join(root, AGENT_CONFIG_RECEIPT))
          return 'it is managed by woods-agent-config; use `woods-agent-config update` to change it'
        end
        return :absent unless File.exist?(path)

        data = JSON.parse(File.read(path))
        return 'it is not a JSON object' unless data.is_a?(Hash)

        servers_reason(data.fetch('mcpServers', {}), entry)
      rescue JSON::ParserError
        'it is not valid JSON'
      end

      # @param path [String] an existing `.mcp.json` {.skip_reason} accepted
      # @param entry [Hash]
      # @return [String] the file with the entry added and every other key kept
      def merged(path, entry)
        data = JSON.parse(File.read(path))
        data['mcpServers'] = (data['mcpServers'] || {}).merge('woods' => entry)
        "#{JSON.pretty_generate(data)}\n"
      end

      def servers_reason(servers, entry)
        return 'its mcpServers is not an object' unless servers.is_a?(Hash)
        return unless servers.key?('woods')
        return :identical if servers['woods'] == entry

        'it already has a different "woods" entry'
      end
      private_class_method :servers_reason
    end
  end
end
