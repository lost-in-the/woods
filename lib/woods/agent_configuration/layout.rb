# frozen_string_literal: true

require 'digest'
require 'pathname'
require_relative 'error'

module Woods
  module AgentConfiguration
    # Explicit client/scope selection; no discovery or fallback into a user home.
    class Layout
      attr_reader :root, :scope, :config_dir

      def initialize(root:, scope:, client: 'claude', home: Dir.home, config_dir: ENV.fetch('CLAUDE_CONFIG_DIR', nil))
        raise Conflict, 'Supported client: claude' unless client == 'claude'
        raise Conflict, 'Select scope project or user explicitly' unless %w[project user].include?(scope)

        @root = File.realpath(root)
        raise Conflict, 'Application root must be a directory' unless File.directory?(@root)

        @scope = scope
        @home = File.expand_path(home)
        @custom_config = config_dir && !config_dir.empty?
        @config_dir = File.expand_path(@custom_config ? config_dir : File.join(@home, '.claude'))
      rescue Errno::ENOENT => e
        raise Conflict, "Application root unavailable: #{e.message}"
      end

      def config_path
        return File.join(root, '.mcp.json') if scope == 'project'

        File.join(@custom_config ? config_dir : @home, '.claude.json')
      end

      def receipt_path
        return File.join(root, '.woods-agent-config.json') if scope == 'project'

        File.join(config_dir, "woods-agent-#{Digest::SHA256.hexdigest(root)[0, 16]}.json")
      end

      def instruction_path(name)
        names = scope == 'project' ? %w[CLAUDE.md AGENTS.md] : ['CLAUDE.md']
        raise Conflict, "Supported #{scope} instruction files: #{names.join(', ')}" unless names.include?(name)

        File.join(scope == 'project' ? root : config_dir, name)
      end

      def allowed_paths
        [config_path, receipt_path, instruction_path('CLAUDE.md')].tap do |paths|
          paths << instruction_path('AGENTS.md') if scope == 'project'
        end
      end

      def identity
        { 'client' => 'claude', 'scope' => scope, 'root' => root, 'config_dir' => config_dir,
          'config_path' => config_path, 'receipt_path' => receipt_path }
      end
    end
  end
end
