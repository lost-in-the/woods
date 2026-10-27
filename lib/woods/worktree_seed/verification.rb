# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'pathname'
require_relative '../atomic_file'
require_relative '../generation'
require_relative '../git_command'
require_relative '../git_provenance'
require_relative '../resilience/incremental_readiness'
require_relative '../source_inputs/private_key'
require_relative '../source_inputs/status'

module Woods
  class WorktreeSeed
    # Raised when the seed cannot be trusted; the caller falls back to a full
    # extraction and reports the message.
    class Unverifiable < StandardError; end

    # Decides whether a published index can seed a new worktree.
    #
    # The index describes its commit exactly only when the checkout it was built
    # from is still on that commit, has no uncommitted changes, and still matches
    # the source the index recorded. Anything less and the git diff taken later
    # would not describe the difference between the index and the worktree.
    class Verification
      # Freshness reasons that do not say the source changed. An extraction that
      # did not start from a fresh-launch handoff cannot vouch for the Ruby boot
      # boundary; the byte comparison of the indexed source is still complete.
      TOLERATED_FRESHNESS_REASONS = %w[unverified_boot_boundary].freeze

      # @param source [Pathname] index directory of the checkout to seed from
      # @param root [Pathname] the new worktree's application root
      def initialize(source:, root:)
        @source = source
        @root = root
      end

      # @return [Hash] the seed's manifest, once it is trusted
      # @raise [Unverifiable] naming the first reason it is not
      def call
        readiness = Resilience::IncrementalReadiness.new(index_dir: @source).call
        raise Unverifiable, "the seed is not incremental-ready (#{readiness.reason})" unless readiness.ready?

        manifest = JSON.parse(AtomicFile.read(payload.join('manifest.json')))
        verify_writer(manifest)
        verify_commit(manifest['git_sha'])
        verify_boot_inputs(manifest)
        verify_source_checkout(manifest['git_sha'])
        raise Unverifiable, 'the seed has no source identity key' unless key_path.file?

        manifest
      end

      private

      def payload
        Generation.new(output_dir: @source).payload_dir
      end

      def key_path
        @source.join(SourceInputs::PrivateKey::FILE_NAME)
      end

      def verify_writer(manifest)
        return if manifest['woods_version'] == Woods::VERSION

        raise Unverifiable, "the seed was written by Woods #{manifest['woods_version'] || 'unknown'}, not #{Woods::VERSION}"
      end

      def verify_commit(sha)
        unless sha.is_a?(String) && sha.match?(/\A\h{7,64}\z/)
          raise Unverifiable, 'the seed records no commit (git_sha is missing or unknown)'
        end

        _out, _err, status = Open3.capture3(*GitCommand.argv(@root, 'cat-file', '-e', "#{sha}^{commit}"))
        raise Unverifiable, "this repository does not have the seed's commit #{sha[0, 12]}" unless status.success?
      end

      # Gitignored boot inputs never show in a git diff, so compare the digests
      # the manifest recorded with this worktree's files (same formulas as the
      # extractor's manifest).
      def verify_boot_inputs(manifest)
        { 'gemfile_lock_sha' => gemfile_lock_digest, 'schema_sha' => schema_digest }.each do |key, current|
          next if manifest[key] == current

          raise Unverifiable, "#{key.delete_suffix('_sha')} differs from the seed's, so its boot inputs differ"
        end
      end

      def gemfile_lock_digest
        path = @root.join('Gemfile.lock')
        path.exist? ? Digest::SHA256.file(path).hexdigest : nil
      end

      def schema_digest
        %w[db/schema.rb db/structure.sql].each do |name|
          path = @root.join(name)
          return Digest::SHA256.file(path).hexdigest if path.exist?
        end
        nil
      end

      def verify_source_checkout(sha)
        root = recorded_root
        raise Unverifiable, 'the seed does not record its source checkout' unless root
        raise Unverifiable, "the seed's source checkout #{root} is not reachable" unless File.directory?(root)

        head = GitProvenance.new(root: root).head_sha
        unless head == sha
          raise Unverifiable,
                "the seed's checkout is at #{head.to_s[0, 12]}, not the indexed #{sha[0, 12]}"
        end

        verify_clean(root)
        verify_matches_index
      end

      def verify_clean(root)
        porcelain, _err, status = Open3.capture3(*GitCommand.argv(root, 'status', '--porcelain'))
        raise Unverifiable, "the seed's checkout #{root} cannot be inspected" unless status.success?
        raise Unverifiable, "the seed's checkout #{root} has uncommitted changes" unless porcelain.strip.empty?
      end

      def verify_matches_index
        freshness = SourceInputs::Status.new(output_dir: @source, mode: 'deep').call
        reasons = Array(freshness['reasons']) - TOLERATED_FRESHNESS_REASONS
        return if %w[current unknown].include?(freshness['state']) && reasons.empty?

        raise Unverifiable, "the seed no longer matches its source (#{([freshness['state']] + reasons).join(': ')})"
      end

      def recorded_root
        data = JSON.parse(AtomicFile.read(payload.join('source_inputs.json')))
        root = data['root']
        root.is_a?(String) && root.start_with?('/') ? root : nil
      rescue SystemCallError, JSON::ParserError
        nil
      end
    end
  end
end
