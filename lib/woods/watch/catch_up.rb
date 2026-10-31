# frozen_string_literal: true

require 'woods/generation'
require 'woods/source_inputs/manifest'
require 'woods/source_inputs/scanner'
require 'woods/source_inputs/stable_reader'
require 'woods/watch/tree_scan'

module Woods
  module Watch
    # Generation-bound startup evidence. Publication time is too late: an edit
    # can land after capture, or even after final verification, before the marker.
    #
    # A candidate (a file modified since capture, or one the capture recorded
    # as dirty) is dropped only when its own bytes still match the keyed digest
    # every scope of the published source manifest records for it (#947): a
    # branch switch, `git checkout -- file` or a stash round trip moves mtimes
    # without changing content. Each check reads one candidate, never the whole
    # tree, so an application larger than a tree scan's budget is still judged.
    # A path with no recorded digest, disagreeing digests, or bytes that cannot
    # be read stably within the bounds stays a candidate.
    class CatchUp
      DIRTY_REASONS = %w[source_changed_during_extraction source_changed_during_read].freeze
      # Wall clock all candidate digest checks may spend together. Candidates
      # left when it runs out are caught up, as they were before the check.
      DIGEST_SECONDS = 30.0

      # @return [Integer] candidates {#paths} dropped because their content
      #   matches the digest the published generation records for them
      attr_reader :unchanged

      # @param root [String] application root, as the source manifest records it
      # @param output_dir [String, Pathname] index root
      # @param ignored [Array<String>] directories the tree walk skips
      def initialize(root:, output_dir:, ignored:)
        @root = root
        @output = output_dir
        @ignored = ignored
        @unchanged = 0
        @generation = Generation.new(output_dir: output_dir)
        @marker = @generation.current
        @manifest = read_manifest
        report_unavailable if @manifest&.unavailable?
      end

      # A full run records the missing boundary even when incremental discovery
      # would find no units to change (and therefore publish no new generation).
      #
      # @return [Boolean] true when a published generation has no usable source manifest
      def rebuild?
        @marker.number.positive? && @manifest.nil?
      end

      # Absolute paths start-up must catch up: every watched file without a
      # usable manifest, else the candidates whose content is not proven
      # unchanged. Sets {#unchanged}.
      #
      # @return [Array<String>]
      def paths
        @unchanged = 0
        files = TreeScan.files(root: @root, ignored: @ignored)
        return files unless @manifest

        candidates = files.select { |path| recent?(path) } | dirty_paths
        return [] if candidates.empty?
        return unavailable_candidates(candidates) if @manifest.unavailable?

        check = UnchangedContent.new(root: @root, key: @key, recorded: recorded_identities)
        kept = candidates.reject { |path| check.unchanged?(path) }
        @unchanged = candidates.size - kept.size
        kept
      end

      # One bounded keyed read per candidate, against every digest the
      # manifest's scopes record for its path.
      class UnchangedContent
        READ_SECONDS = SourceInputs::StableReader::DEFAULT_LIMITS[:max_seconds]

        # @param root [String] application root
        # @param key [SourceInputs::PrivateKey] the key the manifest's digests were made with
        # @param recorded [Hash{String => Array<String>}] relative path => every scope's digest
        def initialize(root:, key:, recorded:)
          @root = root
          @reader = SourceInputs::StableReader.new(root: root, key: key)
          @recorded = recorded
          @deadline = monotonic + DIGEST_SECONDS
        end

        # Every consumer scope must still hold the bytes on disk; one stale
        # sibling scope, a missing digest, an unreadable or unstable file, or
        # an exhausted budget keeps the path a candidate.
        #
        # @param path [String] absolute candidate path
        # @return [Boolean] true only when the bytes match the recorded digest
        def unchanged?(path)
          relative = path.delete_prefix("#{@root}/")
          identities = @recorded[relative]&.uniq
          return false unless identities&.one?

          remaining = @deadline - monotonic
          return false unless remaining.positive?

          @reader.read(relative, identity: identities.first, max_seconds: [remaining, READ_SECONDS].min)
          true
        rescue StandardError
          false
        end

        private

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
      private_constant :UnchangedContent

      private

      def report_unavailable
        evidence = @manifest.data.fetch('unavailable')
        warn "[Woods] Watch source freshness unavailable: #{evidence.fetch('reason')}; " \
             "#{evidence.fetch('size_bytes')} bytes; limit #{evidence.fetch('limit_bytes')}. " \
             'Continuing source-change catch-up without a freshness comparison ledger.'
      end

      # An oversized manifest publishes no per-path digests, only one digest of
      # the whole captured tree: either the tree is unchanged or every
      # candidate is caught up.
      def unavailable_candidates(candidates)
        current = current_identities
        return candidates unless @current_complete

        @manifest.data['capture_sha256'] == SourceInputs::Manifest.capture_digest(current) ? [] : candidates
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
