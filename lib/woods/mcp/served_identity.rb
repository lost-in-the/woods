# frozen_string_literal: true

require 'json'
require 'pathname'
require_relative '../atomic_file'
require_relative '../build_identity'
require_relative '../generation'

module Woods
  module MCP
    # Which checkout, branch, generation and Woods build stand behind a served
    # index, and whether that is the checkout the server was launched in.
    #
    # With several checkouts of one repository, a server's name says nothing
    # about which index it serves. This reads the identity the index recorded
    # (`root`, `git_branch`, the writer build) and compares
    # it with the launcher's working directory, so the server can say so at
    # connect time and `woods-mcp-start` can refuse a server pointed at another
    # checkout's index.
    #
    # Cheap by construction, because it runs before the MCP handshake: it reads
    # `generation.json`, the manifest and the client checkout's `HEAD` file.
    # It runs no `git` process (a released gem never does; a git-loaded build
    # asks for its own revision only when the manifest records one).
    class ServedIdentity
      # Environment override for a root mismatch, equivalent to `--allow-mismatch`.
      ALLOW_ENV = 'WOODS_MCP_ALLOW_MISMATCH'

      # Manifest bytes read at most; a manifest is a few kilobytes.
      MAX_MANIFEST_BYTES = 1_048_576

      # Branch values provenance records for a detached or unresolved HEAD.
      NO_BRANCH = %w[HEAD unknown].freeze

      class << self
        # @param env [Hash]
        # @return [Boolean]
        def allow_mismatch?(env = ENV)
          %w[1 true yes].include?(env.fetch(ALLOW_ENV, '').to_s.strip.downcase)
        end

        # Read once: the marker, then the manifest of the payload that marker
        # names, so a publication between the two cannot pair one
        # generation's number with another's manifest.
        #
        # @param index_dir [String, Pathname]
        # @param cwd [String] the launcher's working directory
        # @param build [BuildIdentity] this reader's build
        # @param manifest [Hash, nil] a manifest to describe instead (specs);
        #   a pinned reader's caller uses {.pinned}
        # @return [ServedIdentity]
        def read(index_dir, cwd: Dir.pwd, build: BuildIdentity.current, manifest: nil)
          generation = Woods::Generation.new(output_dir: index_dir)
          marker = current_marker(generation)
          manifest ||= read_manifest(generation, marker) if marker
          new(index_dir: index_dir, marker: marker, manifest: manifest, cwd: cwd, build: build)
        end

        # The identity of what a pinned reader serves: its loaded generation's
        # marker and manifest, never a fresh read of `generation.json`.
        #
        # @param index_dir [String, Pathname]
        # @param reader [#loaded_marker]
        # @param manifest [Hash, nil] the manifest the caller read inside the pin
        # @param cwd [String]
        # @param build [BuildIdentity]
        # @return [ServedIdentity]
        def pinned(index_dir, reader:, manifest:, cwd: Dir.pwd, build: BuildIdentity.current)
          marker = reader.loaded_marker || Woods::Generation::UNPUBLISHED
          new(index_dir: index_dir, marker: marker, manifest: manifest, cwd: cwd, build: build)
        end

        # The checkout containing +path+: the nearest ancestor holding a
        # `.git` entry (a directory, or the file a linked worktree has).
        #
        # @param path [String, nil]
        # @return [String, nil] real path
        def checkout_root(path)
          return unless path.is_a?(String) && !path.empty? && File.directory?(path)

          Pathname.new(File.realpath(path)).ascend do |dir|
            return dir.to_s if File.exist?(dir.join('.git'))
          end
          nil
        rescue SystemCallError
          nil
        end

        # Files that mark a Rails application root. `config.ru` is the flag
        # Rails itself looks for; `config/application.rb` is the file every
        # generated application has.
        APP_ROOT_MARKERS = %w[config.ru config/application.rb].freeze

        # The application that owns +path+: the nearest ancestor holding an
        # application-root marker. The walk never leaves the checkout that
        # contains +path+ ({.checkout_root}), so it cannot settle on another
        # repository above it; outside any checkout it still stops at the
        # first application root. It reads only the file system and runs no
        # `git` process.
        #
        # @param path [String, nil] usually a served index directory
        # @return [String, nil] real path
        def app_root(path)
          return unless path.is_a?(String) && !path.empty? && File.directory?(path)

          boundary = checkout_root(path)
          Pathname.new(File.realpath(path)).ascend do |dir|
            return dir.to_s if APP_ROOT_MARKERS.any? { |marker| File.file?(dir.join(marker)) }
            return nil if boundary && dir.to_s == boundary
          end
          nil
        rescue SystemCallError
          nil
        end

        # The branch checked out in +checkout+, read from its HEAD file.
        #
        # @param checkout [String, nil]
        # @return [String, nil] nil for a detached or unreadable HEAD
        def checkout_branch(checkout)
          return unless checkout

          head = text(File.binread(File.join(git_dir(checkout), 'HEAD'), 4096))
          head.start_with?('ref: refs/heads/') ? head.delete_prefix('ref: refs/heads/') : nil
        rescue SystemCallError, IOError
          nil
        end

        private

        # Git metadata bytes as stripped UTF-8, independent of the locale.
        def text(bytes)
          bytes.to_s.dup.force_encoding(Encoding::UTF_8).scrub('').strip
        end

        def git_dir(checkout)
          dot_git = File.join(checkout, '.git')
          return dot_git if File.directory?(dot_git)

          pointer = text(File.binread(dot_git, 4096)).delete_prefix('gitdir:').strip
          File.expand_path(pointer, checkout)
        end

        # An unusable marker identifies nothing; woods_status reports it.
        def current_marker(generation)
          generation.current
        rescue StandardError
          nil
        end

        def read_manifest(generation, marker)
          path = generation.payload_dir(marker).join('manifest.json')
          return unless path.file? && path.size <= MAX_MANIFEST_BYTES

          data = JSON.parse(AtomicFile.read(path))
          data.is_a?(Hash) ? data : nil
        rescue StandardError
          nil
        end
      end

      attr_reader :index_dir, :manifest

      # @param index_dir [String, Pathname]
      # @param marker [Woods::Generation::Marker]
      # @param manifest [Hash, nil]
      # @param cwd [String]
      # @param build [BuildIdentity]
      def initialize(index_dir:, marker:, manifest:, cwd:, build:)
        @index_dir = index_dir.to_s
        @marker = marker || Woods::Generation::UNPUBLISHED
        @manifest = manifest.is_a?(Hash) ? manifest : {}
        @cwd = cwd
        @build = build
      end

      # @return [String, nil] the checkout the index recorded as its source
      def recorded_root
        root = string(@manifest['root'])
        root&.start_with?('/') ? root : nil
      end

      # The checkout the index describes: the one containing the recorded
      # root when this process can reach it (an application in a
      # subdirectory belongs to the repository above it), otherwise the one
      # containing the index directory. The fallback covers an index that
      # records no root and one written where its root had another path (a
      # container's `/app` read through a bind mount); it is the rule
      # worktree routing uses.
      #
      # @return [String, nil]
      def recorded_checkout
        return @recorded_checkout if defined?(@recorded_checkout)

        @recorded_checkout = self.class.checkout_root(recorded_root) || self.class.checkout_root(@index_dir)
      end

      # @return [String, nil] `recorded_root` or `index_location`
      def root_source
        return unless recorded_checkout

        recorded_root && self.class.checkout_root(recorded_root) ? 'recorded_root' : 'index_location'
      end

      # @return [String, nil] the repository root's directory name
      def root_name
        root = recorded_checkout || recorded_root
        root && File.basename(root)
      end

      # @return [String, nil]
      def branch
        value = string(@manifest['git_branch'])
        value && !NO_BRANCH.include?(value) ? value : nil
      end

      # @return [Integer, nil]
      def generation
        @marker.number.zero? ? nil : @marker.number
      end

      # @return [String, nil]
      def generation_updated_at
        @marker.updated_at
      end

      # @return [BuildComparison]
      def compatibility
        @compatibility ||= BuildIdentity.compare(@manifest, reader: @build)
      end

      # @return [String, nil] the checkout containing the launcher's directory
      def client_root
        return @client_root if defined?(@client_root)

        @client_root = self.class.checkout_root(@cwd)
      end

      # @return [String, nil]
      def client_branch
        return @client_branch if defined?(@client_branch)

        @client_branch = self.class.checkout_branch(client_root)
      end

      # Whether the index's recorded checkout is the launcher's checkout.
      #
      # nil when it cannot be told: neither the recorded root nor the index
      # directory is inside a checkout this process can reach, or the
      # launcher is outside any checkout.
      #
      # @return [Boolean, nil]
      def client_matches
        case match_reason
        when 'same_checkout' then true
        when 'different_checkout' then false
        end
      end

      # @return [String] same_checkout, different_checkout, root_not_recorded,
      #   client_outside_checkout or recorded_root_unreachable
      def match_reason
        @match_reason ||= compute_match_reason
      end

      # @return [Boolean, nil] nil when either side has no branch (detached HEAD)
      def branch_matches
        return nil unless client_matches && branch && client_branch

        branch == client_branch
      end

      # @return [Hash] the identity block that leads `woods_status`
      def to_h
        {
          root: recorded_root, repository_root: recorded_checkout, root_source: root_source, root_name: root_name, branch: branch, git_sha: string(@manifest['git_sha']),
          generation: generation, generation_updated_at: generation_updated_at,
          woods_version: string(@manifest['woods_version']), woods_revision: compatibility.writer_revision,
          woods_revision_dirty: compatibility.writer_dirty,
          client_matches: client_matches, client_match_reason: match_reason,
          client_root: client_root, client_branch: client_branch, branch_matches: branch_matches,
          mismatch_allowed: client_matches == false ? self.class.allow_mismatch? : nil,
          build: compatibility.to_h
        }
      end

      # The line `initialize` instructions lead with.
      #
      # @return [String]
      def summary
        "Serving the index of #{root_name || 'an unrecorded checkout'}" \
          "#{" (#{recorded_checkout || recorded_root})" if recorded_checkout || recorded_root}, branch #{branch || 'unknown or detached'}, " \
          "generation #{generation || 'none'}#{", updated #{generation_updated_at}" if generation_updated_at}, " \
          "written by #{writer_label}."
      end

      # @return [Array<String>] mismatch and build warnings, most severe first
      def warnings
        list = []
        list << root_warning if client_matches == false
        list << branch_warning if branch_matches == false
        list << compatibility.message if compatibility.mismatch?
        list
      end

      # @return [String] why `woods-mcp-start` refuses
      def refusal_message
        "This index was written for the checkout at #{recorded_checkout}, but the server was launched in " \
          "#{client_root}. Point the server at this checkout's own index, or pass --allow-mismatch " \
          "(#{ALLOW_ENV}=1) to serve it anyway."
      end

      private

      def writer_label
        version = string(@manifest['woods_version'])
        return 'an unknown Woods version' unless version

        revision = compatibility.writer_revision
        return "Woods #{version}" unless revision

        "Woods #{version} (#{BuildIdentity.short(revision)}#{'-dirty' if compatibility.writer_dirty})"
      end

      def root_warning
        "This index describes #{recorded_checkout}, not the launch checkout #{client_root}; answers are for that " \
          'checkout.'
      end

      def branch_warning
        "The index was extracted on branch #{branch}; this checkout is on #{client_branch}."
      end

      def compute_match_reason
        unless recorded_checkout
          return recorded_root ? 'recorded_root_unreachable' : 'root_not_recorded'
        end
        return 'client_outside_checkout' unless client_root

        # Compare checkouts, not paths: a worktree nested inside another
        # checkout is still its own checkout.
        recorded_checkout == client_root ? 'same_checkout' : 'different_checkout'
      end

      def string(value)
        value.is_a?(String) && !value.empty? ? value : nil
      end
    end
  end
end
