# frozen_string_literal: true

require 'woods/generation'
require 'woods/source_inputs/manifest'
require 'woods/source_inputs/scanner'
require 'woods/watch/tree_scan'

module Woods
  module Watch
    # Generation-bound startup evidence. Publication time is too late: an edit
    # can land after capture, or even after final verification, before the marker.
    class CatchUp
      DIRTY_REASONS = %w[source_changed_during_extraction source_changed_during_read].freeze

      def initialize(root:, output_dir:, ignored:)
        @root = root
        @output = output_dir
        @ignored = ignored
        @generation = Generation.new(output_dir: output_dir)
        @marker = @generation.current
        @manifest = read_manifest
      end

      # A full run records the missing boundary even when incremental discovery
      # would find no units to change (and therefore publish no new generation).
      def rebuild?
        @marker.number.positive? && @manifest.nil?
      end

      def paths
        files = TreeScan.files(root: @root, ignored: @ignored)
        return files unless @manifest

        candidates = files.select { |path| recent?(path) } | dirty_paths
        return [] if candidates.empty?

        current = current_identities
        return [] if captured_tree_matches?(current)

        expected = recorded_identities
        candidates.reject { |path| covered?(path, current, expected) }
      end

      private

      def captured_tree_matches?(current)
        @manifest.unavailable? && @current_complete &&
          @manifest.data['capture_sha256'] == SourceInputs::Manifest.capture_digest(current)
      end

      def covered?(path, current, expected)
        relative = path.delete_prefix("#{@root}/")
        identities = expected[relative]
        identities && current[relative] && identities.all? { |identity| identity == current[relative] }
      end

      def read_manifest
        payload = @generation.payload_dir(@marker)
        return nil if @marker.payload && payload == @generation.root

        manifest = load_manifest(payload)
        data = manifest.data
        return nil unless matching_manifest?(data)

        @key = SourceInputs::PrivateKey.new(output_dir: @output)
        @scopes = SourceInputs::Scopes.new(extra_roots: data.fetch('extra_roots'))
        return nil unless @key.identifier == data['key_id'] && @scopes.fingerprint == data['rules']

        manifest
      rescue SourceInputs::Manifest::Invalid, SourceInputs::PrivateKey::Unavailable, SystemCallError, IOError, TypeError
        nil
      end

      def matching_manifest?(data)
        data['root'] == @root && data['generation'] == @marker.number &&
          data['captured_at'] && data['captured_at'] <= Time.now.to_f
      end

      def load_manifest(payload)
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(payload.join(SourceInputs::Manifest::FILE_NAME), flags) do |file|
          unless file.stat.file? && file.stat.size <= SourceInputs::Manifest::MAX_BYTES
            raise SourceInputs::Manifest::Invalid, 'invalid_source_manifest'
          end

          SourceInputs::Manifest.parse(file.read(SourceInputs::Manifest::MAX_BYTES + 1))
        end
      end

      def recent?(path)
        # Filesystems may record only whole seconds. Include the entire capture
        # second; content comparison below prevents unchanged files repeating.
        File.mtime(path).to_f >= @manifest.data.fetch('captured_at').floor
      rescue SystemCallError
        false
      end

      def dirty_paths
        @manifest.data.fetch('errors').filter_map do |error|
          next unless DIRTY_REASONS.include?(error['reason'])

          path = error['path']
          next unless relative_path?(path)

          File.join(@root, path)
        end
      end

      def relative_path?(path)
        path.is_a?(String) && !path.empty? && !path.start_with?('/') && !path.include?("\0") &&
          path.split('/', -1).none? { |part| ['', '.', '..'].include?(part) }
      end

      def recorded_identities
        @manifest.expanded.each_value.with_object({}) do |paths, result|
          paths.each { |path, identity| (result[path] ||= []) << identity }
        end
      end

      def current_identities
        snapshot = SourceInputs::Scanner.new(root: @root, output_dir: @output, key: @key, scopes: @scopes).call
        @current_complete = snapshot['complete']
        snapshot.fetch('files')
      rescue SystemCallError, IOError
        {}
      end
    end
  end
end
