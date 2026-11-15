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

      # The directory the client session runs in, equivalent to
      # `--client-root`. When set, the launch compares the index with this
      # checkout instead of the launcher's own directory.
      CLIENT_ROOT_ENV = 'WOODS_MCP_CLIENT_ROOT'

      # Where this process sees the client root, equivalent to
      # `--client-root-as`, for a client root on another file system (a host
      # path read inside a container).
      CLIENT_ROOT_AS_ENV = 'WOODS_MCP_CLIENT_ROOT_AS'

      # Manifest bytes read at most; a manifest is a few kilobytes.
      MAX_MANIFEST_BYTES = 1_048_576

      # Branch values provenance records for a detached or unresolved HEAD.
      NO_BRANCH = %w[HEAD unknown].freeze

      class << self
        # @param env [Hash]
        # @return [Boolean]
        def allow_mismatch?(env = ENV)
          env_flag?(ALLOW_ENV, env)
        end

        # @param name [String] a launch flag's environment variable
        # @param env [Hash]
        # @return [Boolean] true for 1, true or yes
        def env_flag?(name, env = ENV)
          %w[1 true yes].include?(env.fetch(name, '').to_s.strip.downcase)
        end

        # The client of this launch: the client root {CLIENT_ROOT_ENV}
        # declares, resolved at {CLIENT_ROOT_AS_ENV} when that is set, else
        # the launcher's own directory.
        #
        # @param env [Hash]
        # @param pwd [String]
        # @return [Array(String, String, String)] the directory to resolve the
        #   client checkout from, the declared client root (or nil) and the
        #   path it was mapped to (or nil)
        def launch_client(env = ENV, pwd: Dir.pwd)
          declared = env[CLIENT_ROOT_ENV].to_s.strip
          return [pwd, nil, nil] if declared.empty?

          mapped = env[CLIENT_ROOT_AS_ENV].to_s.strip
          mapped.empty? ? [declared, declared, nil] : [mapped, declared, mapped]
        end

        # Read once: the marker, then the manifest of the payload that marker
        # names, so a publication between the two cannot pair one
        # generation's number with another's manifest.
        #
        # @param index_dir [String, Pathname]
        # @param cwd [String, nil] the client's directory; nil means this
        #   launch's client ({.launch_client})
        # @param build [BuildIdentity] this reader's build
        # @param manifest [Hash, nil] a manifest to describe instead (specs);
        #   a pinned reader's caller uses {.pinned}
        # @return [ServedIdentity]
        def read(index_dir, cwd: nil, build: BuildIdentity.current, manifest: nil)
          generation = Woods::Generation.new(output_dir: index_dir)
          marker = current_marker(generation)
          manifest ||= read_manifest(generation, marker) if marker
          new(index_dir: index_dir, marker: marker, manifest: manifest, build: build, **client_for(cwd))
        end

        # The identity of what a pinned reader serves: its loaded generation's
        # marker and manifest, never a fresh read of `generation.json`.
        #
        # @param index_dir [String, Pathname]
        # @param reader [#loaded_marker]
        # @param manifest [Hash, nil] the manifest the caller read inside the pin
        # @param cwd [String, nil] as for {.read}
        # @param build [BuildIdentity]
        # @return [ServedIdentity]
        def pinned(index_dir, reader:, manifest:, cwd: nil, build: BuildIdentity.current)
          marker = reader.loaded_marker || Woods::Generation::UNPUBLISHED
          new(index_dir: index_dir, marker: marker, manifest: manifest, build: build, **client_for(cwd))
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

        def client_for(cwd)
          return { cwd: cwd } if cwd

          directory, declared, mapped = launch_client
          { cwd: directory, declared_client_root: declared, mapped_client_root: mapped }
        end

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
      # @param cwd [String] the directory the client checkout is resolved from
      # @param build [BuildIdentity]
      # @param declared_client_root [String, nil] the client root a launch
      #   declared, as the client names it
      # @param mapped_client_root [String, nil] where this process sees it
      def initialize(index_dir:, marker:, manifest:, cwd:, build:, declared_client_root: nil,
                     mapped_client_root: nil)
        @index_dir = index_dir.to_s
        @marker = marker || Woods::Generation::UNPUBLISHED
        @manifest = manifest.is_a?(Hash) ? manifest : {}
        @cwd = cwd
        @build = build
        @declared_client_root = declared_client_root
        @mapped_client_root = mapped_client_root
      end

      # @return [String, nil] the client root the launch declared
      attr_reader :declared_client_root

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

        @recorded_checkout = self.class.checkout_root(recorded_root) || self.class.checkout_root(index_location)
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
      #   recorded_root_unreachable, client_outside_checkout or
      #   client_root_unresolved
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
          root: recorded_root, repository_root: recorded_checkout, root_source: root_source, root_name: root_name,
          branch: branch, git_sha: string(@manifest['git_sha']),
          generation: generation, generation_updated_at: generation_updated_at,
          woods_version: string(@manifest['woods_version']), woods_revision: compatibility.writer_revision,
          woods_revision_dirty: compatibility.writer_dirty,
          client_matches: client_matches, client_match_reason: match_reason,
          client_root: client_root, client_root_declared: @declared_client_root,
          client_root_mapped_to: @mapped_client_root, client_branch: client_branch, branch_matches: branch_matches,
          mismatch_allowed: client_matches == false ? self.class.allow_mismatch? : nil,
          warnings: warnings, build: compatibility.to_h
        }
      end

      # The line `initialize` instructions lead with. A declared client root
      # that matches names the checkout as the client knows it (a host path),
      # beside the path this process reads it at.
      #
      # @return [String]
      def summary
        "Serving the index of #{served_name || 'an unrecorded checkout'}" \
          "#{" (#{served_location})" if served_location}, " \
          "branch #{branch || 'unknown or detached'}, " \
          "generation #{generation || 'none'}#{", updated #{generation_updated_at}" if generation_updated_at}, " \
          "written by #{writer_label}."
      end

      # @return [Array<String>] mismatch, unknown-checkout and build warnings,
      #   most severe first
      def warnings
        list = []
        list << root_warning if client_matches == false
        list << unknown_checkout_warning if client_matches.nil?
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

      # One line for either side, or both, that cannot be determined.
      def unknown_checkout_warning
        sides = []
        sides << unknown_index_side unless recorded_checkout
        sides << unknown_client_side unless client_root
        "Cannot tell whether this index belongs to the client's checkout: #{sides.join('; ')}"
      end

      def unknown_index_side
        unless recorded_root
          return "the index's checkout is unknown: it records no root, and the index directory #{@index_dir} " \
                 'is not inside a git checkout'
        end

        "the index's checkout is unknown: it records root #{recorded_root}, and neither that nor the index " \
          "directory #{@index_dir} is inside a git checkout reachable here"
      end

      def unknown_client_side
        unless @declared_client_root
          return "the client's checkout is unknown: the launch directory #{@cwd} is not inside a git checkout " \
                 "(pass --client-root with the session's checkout)"
        end

        "the client's checkout is unknown: the client root #{@declared_client_root} does not resolve to a git " \
          "checkout here#{" at #{@mapped_client_root}" if @mapped_client_root} " \
          '(pass --client-root-as with the path where this process sees it)'
      end

      # A client root declared through --client-root-as that matched: the
      # index's checkout is the one the client names by that host path.
      def mapped_match?
        @mapped_client_root && client_matches == true
      end

      def served_name
        mapped_match? ? File.basename(@declared_client_root) : root_name
      end

      def served_location
        return "#{@declared_client_root}, mapped to #{recorded_checkout}" if mapped_match?

        recorded_checkout || recorded_root
      end

      # The index directory, or its nearest existing ancestor while no index
      # has been written there yet.
      def index_location
        Pathname.new(File.expand_path(@index_dir)).ascend { |dir| return dir.to_s if dir.directory? }
        nil
      end

      def branch_warning
        "The index was extracted on branch #{branch}; this checkout is on #{client_branch}."
      end

      def compute_match_reason
        unless recorded_checkout
          return recorded_root ? 'recorded_root_unreachable' : 'root_not_recorded'
        end
        return @declared_client_root ? 'client_root_unresolved' : 'client_outside_checkout' unless client_root

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
