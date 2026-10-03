# frozen_string_literal: true

require 'json'
require 'woods/source_inputs/manifest'

module Woods
  module SourceInputs
    # Private one-process launch handoff. Its environment token names neither an
    # existing index manifest nor a user-supplied proof of runtime freshness.
    module Handoff # rubocop:disable Metrics/ModuleLength -- one-use capture consumption plus its binding diagnostics
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

      # Every independent handoff binding must match before a token is consumed.
      # A capture the launcher handed off but this process cannot consume is
      # reported once on stderr by the binding that failed, never by value: the
      # run then publishes boot_verified: false, and without the line that
      # downgrade was invisible (F4). A descriptor without a capture path (the
      # launcher ran without capture and said so itself) is not a handoff.
      def read(root:, output_dir:, operation:, rules:, key_id:)
        token = ENV.fetch(ENV_KEY, nil)
        return nil if token.nil? || token.empty?

        snapshot, failed = consume(token, root: root, output_dir: output_dir, operation: operation,
                                          rules: rules, key_id: key_id)
        if snapshot.nil? && failed
          warn "woods-extract: launch handoff discarded (#{failed}); source freshness is unverified for this run"
        end
        snapshot
      end

      # @return [Array(Hash, nil), Array(nil, String), Array(nil, nil)] the
      #   consumed snapshot, or the failed binding, or nothing to consume
      def consume(token, **bindings)
        descriptor = JSON.parse(token)
        return [nil, nil] unless descriptor.is_a?(Hash) && descriptor.key?('path')

        data = private_data(descriptor.fetch('path'))
        return [nil, 'capture file'] unless data.is_a?(Hash)

        expected = expected_bindings(descriptor, **bindings.slice(:root, :output_dir, :operation, :rules))
        failed = failed_binding(data, expected, bindings.fetch(:key_id))
        return [nil, failed] if failed

        ENV.delete(ENV_KEY)
        [data.fetch('snapshot'), nil]
      rescue JSON::ParserError, KeyError, TypeError, SystemCallError, IOError
        [nil, 'capture file']
      end

      # The root binds to the physical path on both sides: the launcher
      # resolves --root with File.realpath before capturing, and the child
      # resolves its own root here, so a symlink alias on either side matches.
      def expected_bindings(descriptor, root:, output_dir:, operation:, rules:)
        { 'version' => 1, 'nonce' => descriptor.fetch('nonce'),
          'root' => physical_root(root), 'output' => File.expand_path(output_dir.to_s),
          'operation' => operation.to_s, 'rules' => rules, 'launcher_pid' => Process.ppid }
      end

      def physical_root(root)
        expanded = File.expand_path(root.to_s)
        File.realpath(expanded)
      rescue SystemCallError
        expanded
      end

      BINDING_LABELS = { 'launcher_pid' => 'parent process' }.freeze

      # The first binding that does not hold, as a label safe to print.
      def failed_binding(data, expected, key_id)
        mismatch = expected.find { |key, value| data[key] != value }
        return BINDING_LABELS.fetch(mismatch.first, mismatch.first) if mismatch
        return 'nonce' unless valid_nonce?(data['nonce'])
        return 'snapshot' unless valid_snapshot?(data.fetch('snapshot'), expected, key_id)

        nil
      end

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
