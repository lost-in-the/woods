# frozen_string_literal: true

require 'json'
require 'woods/mcp/served_identity'

module Woods
  module Generators
    # The Index Server entry the install generator prints or adds to an MCP
    # client's `.mcp.json`, and the rules for adding it to an existing file.
    #
    # The entry names no absolute path and no `cwd`: `woods-mcp-start
    # --checkout` finds the checkout the client starts it in, and
    # `--await-index` starts it before that checkout's first index exists.
    module McpConfiguration
      # A Compose service name: what `docker compose exec` takes, and safe to
      # place in the shell command the container entry runs.
      SERVICE_NAME = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/

      # A file `woods-agent-config` writes beside a `.mcp.json` it manages.
      AGENT_CONFIG_RECEIPT = '.woods-agent-config.json'

      LAUNCH = %w[bundle exec woods-mcp-start --checkout --await-index].freeze

      module_function

      # A container launch runs through `sh -c` so `$PWD` becomes the session
      # directory, handed over as the client root. The developer's own mount
      # map, when exported, goes in through the environment, so the committed
      # entry holds no host path.
      #
      # @param service [String, nil] the Compose service; nil for a host launch
      # @param output [String, nil] the index relative to the checkout root,
      #   for an application below it (host launch only)
      # @return [Hash]
      def entry(service: nil, output: nil)
        return { 'command' => LAUNCH.first, 'args' => LAUNCH.drop(1) }.merge(output_env(output)) unless service

        map = Woods::MCP::ServedIdentity::CLIENT_ROOT_MAP_ENV
        { 'command' => 'sh',
          'args' => ['-c', "exec docker compose exec -T -e #{map}=\"${#{map}:-}\" #{service} " \
                           "#{LAUNCH.join(' ')} --client-root \"$PWD\""] }
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

      def output_env(output)
        output ? { 'env' => { 'WOODS_OUTPUT' => output } } : {}
      end
      private_class_method :output_env
    end
  end
end
