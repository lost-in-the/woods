# frozen_string_literal: true

require 'json'

module Woods
  module Evaluation
    # A task set for the agent-level ablation (#280): the same coding tasks
    # run with the Woods index on and off.
    #
    # File shape (schema_version 1):
    #
    #   {
    #     "schema_version": 1,
    #     "agent_on":  "claude -p {prompt} --output-format json --mcp-config .mcp.json",
    #     "agent_off": "claude -p {prompt} --output-format json --strict-mcp-config",
    #     "reset":     "git checkout -- . && git clean -fdq",   // optional
    #     "tasks": [
    #       { "id": "...", "prompt": "...", "check": "bin/rspec spec/...", "workdir": "." }
    #     ]
    #   }
    #
    # `{prompt}` is replaced with the shell-escaped prompt. `check` is any
    # command whose exit status says whether the task was resolved.
    class AblationTaskSet
      SUPPORTED_SCHEMA_VERSIONS = [1].freeze

      Task = Struct.new(:id, :prompt, :check, :workdir, keyword_init: true)

      # Named `Definition` rather than `Data`: Ruby 3.2 introduces a
      # top-level `::Data` class, and shadowing it inside this class body is
      # legal on the 3.0 floor but confusing to read.
      Definition = Struct.new(:schema_version, :agent_on, :agent_off, :reset, :tasks, keyword_init: true)

      class << self
        # @param path [String]
        # @return [Definition]
        # @raise [Woods::Error] on an unreadable file, invalid JSON, or an invalid shape
        def load(path)
          raw = JSON.parse(File.read(path.to_s, encoding: 'UTF-8'))
          version = raw['schema_version']
          unless SUPPORTED_SCHEMA_VERSIONS.include?(version)
            raise Woods::Error, "Unsupported ablation schema_version #{version.inspect} in #{path}"
          end

          Definition.new(
            schema_version: version,
            agent_on: command!(raw, 'agent_on', path),
            agent_off: command!(raw, 'agent_off', path),
            reset: raw['reset'],
            tasks: Array(raw['tasks']).map { |task| build_task(task, path) }
          )
        rescue JSON::ParserError => e
          raise Woods::Error, "Invalid JSON in ablation task set #{path}: #{e.message}"
        rescue Errno::ENOENT => e
          raise Woods::Error, "Ablation task set not found: #{e.message}"
        end

        private

        def command!(raw, key, path)
          value = raw[key].to_s
          raise Woods::Error, "#{key} in #{path} must contain {prompt}" unless value.include?('{prompt}')

          value
        end

        def build_task(task, path)
          %w[id prompt check].each do |key|
            raise Woods::Error, "Task #{task['id'].inspect} in #{path} is missing #{key}" if task[key].to_s.empty?
          end

          Task.new(id: task['id'], prompt: task['prompt'], check: task['check'], workdir: task['workdir'] || '.')
        end
      end
    end
  end
end
