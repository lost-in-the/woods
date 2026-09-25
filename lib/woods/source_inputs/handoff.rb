# frozen_string_literal: true

require 'json'
require 'woods/source_inputs/manifest'

module Woods
  module SourceInputs
    # Private one-process launch handoff. Its environment token names neither an
    # existing index manifest nor a user-supplied proof of runtime freshness.
    module Handoff
      ENV_KEY = 'WOODS_SOURCE_CAPTURE'
      class OutputMismatch < StandardError; end

      module_function

      # An implicit preboot default cannot override finalized application config.
      # Explicit launcher outputs remain intentional overrides. Called before
      # the writer lock/extraction, while the one-use handoff is still present.
      # @param root [String, Pathname] finalized application root
      # @param output_dir [String, Pathname] selected writer output
      # @return [void]
      def validate_output!(root:, output_dir:)
        token = ENV.fetch(ENV_KEY, nil)
        return if token.to_s.empty?

        descriptor = JSON.parse(token)
        return unless descriptor.is_a?(Hash) && descriptor['implicit_output'] == true

        expected = File.expand_path('tmp/woods', root.to_s)
        configured = File.expand_path(Woods.configuration.output_dir.to_s, root.to_s)
        return if configured == expected && File.expand_path(output_dir.to_s, root.to_s) == expected

        raise OutputMismatch,
              "woods-extract configured output #{configured.inspect} differs from " \
              "its preboot default #{expected.inspect}; " \
              'rerun with matching --output PATH or WOODS_OUTPUT so capture and publication use the same index'
      rescue JSON::ParserError, TypeError
        nil # Ordinary handoff validation will refuse unverifiable capture.
      end

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      # Every independent handoff binding must match before a token is consumed.
      def read(root:, output_dir:, operation:, rules:, key_id:)
        token = ENV.fetch(ENV_KEY, nil)
        return nil if token.nil? || token.empty?

        descriptor = JSON.parse(token)
        return nil unless descriptor.is_a?(Hash)

        data = private_data(descriptor.fetch('path'))
        return nil unless data.is_a?(Hash)

        expected = { 'version' => 1, 'nonce' => descriptor.fetch('nonce'),
                     'root' => File.expand_path(root.to_s), 'output' => File.expand_path(output_dir.to_s),
                     'operation' => operation.to_s, 'rules' => rules, 'launcher_pid' => Process.ppid }
        return nil unless expected.all? { |key, value| data[key] == value }
        return nil unless valid_nonce?(data['nonce'])

        snapshot = data.fetch('snapshot')
        return nil unless valid_snapshot?(snapshot, expected, key_id)

        ENV.delete(ENV_KEY)
        snapshot
      rescue JSON::ParserError, KeyError, TypeError, SystemCallError, IOError
        nil
      end

      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      def private_data(path)
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |file|
          stat = file.stat
          return nil unless stat.file? && stat.uid == Process.uid && stat.mode.nobits?(0o077)
          return nil if stat.size > Manifest::MAX_BYTES

          JSON.parse(file.read(Manifest::MAX_BYTES + 1))
        end
      end

      def valid_nonce?(value)
        value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
      end

      def valid_snapshot?(snapshot, expected, key_id)
        return false unless matching_snapshot?(snapshot, expected, key_id)

        files = snapshot['files']
        paths = snapshot['scope_paths']
        return false unless valid_tables?(files, paths)

        expanded = paths.transform_values { |list| list.to_h { |path| [path, files.fetch(path)] } }
        Manifest.build(snapshot: snapshot, scopes: expanded, boot_verified: true, generation: 1)
        true
      rescue Manifest::Invalid, KeyError, TypeError
        false
      end

      def matching_snapshot?(snapshot, expected, key_id)
        snapshot.is_a?(Hash) && snapshot['root'] == expected['root'] &&
          snapshot['rules'] == expected['rules'] && snapshot['key_id'] == key_id
      end

      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def valid_tables?(files, paths)
        files.is_a?(Hash) && paths.is_a?(Hash) &&
          files.all? { |path, digest| path.is_a?(String) && valid_nonce?(digest) } &&
          paths.values.all? { |list| list.is_a?(Array) && list.all? { |path| files.key?(path) } }
      end

      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # An oversized launcher capture conveys only a downgrade, never proof.
      def unavailable_evidence
        descriptor = JSON.parse(ENV.fetch(ENV_KEY, '{}'))
        value = descriptor.is_a?(Hash) && descriptor['unavailable']
        return unless Manifest.valid_unavailable_evidence?(value)

        value.slice('reason', 'size_bytes', 'limit_bytes')
      rescue JSON::ParserError
        nil
      end

      def extra_roots
        token = ENV.fetch(ENV_KEY, nil)
        return [] if token.nil? || token.empty?

        descriptor = JSON.parse(token)
        return [] unless descriptor.is_a?(Hash)

        roots = descriptor.fetch('extra_roots', [])
        roots.is_a?(Array) ? roots : []
      rescue JSON::ParserError, TypeError
        []
      end
    end
  end
end
