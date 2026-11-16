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

      # Bind mounts between the client's file system and this process's,
      # equivalent to repeated `--client-root-map HOST=CONTAINER`: entries of
      # absolute `host_prefix=container_prefix`, separated by `:`. A client
      # root is read here through the entry with the longest host prefix
      # that contains it; under none, its checkout is not mounted here.
      CLIENT_ROOT_MAP_ENV = 'WOODS_MCP_CLIENT_ROOT_MAP'

      # What the client's checkout is, without its path, equivalent to
      # `--client-identity`: `main|linked:HEAD-sha:branch` (sha and branch may
      # be empty). A container launch with no map cannot read the client root,
      # so it compares this with the checkout it serves instead.
      CLIENT_IDENTITY_ENV = 'WOODS_MCP_CLIENT_IDENTITY'

      # A well-formed {CLIENT_IDENTITY_ENV} value. Git refuses `:` in branch
      # names, so the branch is everything after the second one.
      CLIENT_IDENTITY = /\A(main|linked):([0-9a-f]{0,64}):([^:\n]*)\z/

      # Separates entries of {CLIENT_ROOT_MAP_ENV}.
      MAP_SEPARATOR = ':'

      # Raised for a client root map entry that is not two absolute prefixes.
      class InvalidClientRootMap < ArgumentError; end

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
        # declares, read through {CLIENT_ROOT_MAP_ENV} when a map is set, else
        # the launcher's own directory.
        #
        # @param env [Hash]
        # @param pwd [String]
        # @return [Hash] keywords for {#initialize}: `cwd:` and, for a declared
        #   client root, `declared_client_root:` and `client_root_map:`
        def launch_client(env = ENV, pwd: Dir.pwd)
          declared = env[CLIENT_ROOT_ENV].to_s.strip
          return { cwd: pwd } if declared.empty?

          map = parse_client_root_map(env[CLIENT_ROOT_MAP_ENV])
          { cwd: declared, declared_client_root: declared, client_root_map: map,
            client_identity: parse_client_identity(env[CLIENT_IDENTITY_ENV]) }
        rescue InvalidClientRootMap => e
          { cwd: nil, declared_client_root: declared, client_root_map_error: e.message }
        end

        # @param value [String, nil] a {CLIENT_IDENTITY_ENV} value
        # @return [Hash, nil] `worktree:`, `head:` and `branch:` (nil when
        #   empty), or nil for a missing or malformed value
        def parse_client_identity(value)
          match = CLIENT_IDENTITY.match(value.to_s.strip)
          return unless match

          { worktree: match[1], head: (match[2] unless match[2].empty?), branch: (match[3] unless match[3].empty?) }
        end

        # What +checkout+ is, read from its git files without running git.
        #
        # @param checkout [String, nil]
        # @return [Hash, nil] `worktree:` (`main` or `linked`), `head:` and
        #   `branch:` (nil when unreadable or detached)
        def checkout_identity(checkout)
          return unless checkout

          { worktree: File.directory?(File.join(checkout, '.git')) ? 'main' : 'linked',
            head: checkout_head(checkout), branch: checkout_branch(checkout) }
        end

        # @param checkout [String]
        # @return [String, nil] the HEAD commit: a detached sha, or the ref it
        #   names, loose or packed, in the checkout's own or common git dir
        def checkout_head(checkout)
          dir = git_dir(checkout)
          head = text(File.binread(File.join(dir, 'HEAD'), 4096))
          return head if head.match?(/\A[0-9a-f]{40,64}\z/)
          return unless head.start_with?('ref: ')

          ref = head.delete_prefix('ref: ')
          [dir, common_dir(dir)].uniq.each do |base|
            loose = File.join(base, ref)
            return text(File.binread(loose, 128)) if File.file?(loose)

            packed = File.join(base, 'packed-refs')
            next unless File.file?(packed)

            line = File.foreach(packed).find { |entry| entry.split(' ', 2)[1].to_s.strip == ref }
            return line.split(' ', 2).first if line
          end
          nil
        rescue SystemCallError, IOError
          nil
        end

        # @param value [String, nil] {CLIENT_ROOT_MAP_ENV} entries
        # @return [Array<Array(String, String)>] normalized host and container
        #   prefixes, in the order given
        # @raise [InvalidClientRootMap]
        def parse_client_root_map(value)
          value.to_s.split(MAP_SEPARATOR).reject { |entry| entry.strip.empty? }.map do |entry|
            host, container, extra = entry.strip.split('=', 3)
            unless extra.nil? && absolute?(host) && absolute?(container)
              raise InvalidClientRootMap, "#{entry.strip.inspect} is not HOST_PREFIX=CONTAINER_PREFIX with two " \
                                          'absolute paths'
            end

            [normalize_prefix(host), normalize_prefix(container)]
          end
        end

        # The path this process reads +path+ at: the entry whose host prefix
        # contains it in whole path segments, the longest when several do.
        # The host side is never resolved on this file system.
        #
        # @param path [String] an absolute client path
        # @param map [Array<Array(String, String)>]
        # @return [Array(String, Array(String, String)), nil] the derived path
        #   and the entry used, or nil under no host prefix
        def map_client_root(path, map)
          path = normalize_prefix(path)
          entry = map.select { |host, _| within_prefix?(path, host) }.max_by { |host, _| host.length }
          return unless entry

          host, container = entry
          rest = path.delete_prefix(host).delete_prefix('/')
          [rest.empty? ? container : File.join(container, rest), entry]
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
          cwd ? { cwd: cwd } : launch_client
        end

        def absolute?(path)
          path.is_a?(String) && path.start_with?('/')
        end

        # Lexical only: collapses repeated and trailing slashes and dot
        # segments, follows no symlink.
        def normalize_prefix(path)
          File.expand_path(path.sub(%r{\A/+}, '/'))
        end

        def within_prefix?(path, prefix)
          prefix == '/' || path == prefix || path.start_with?("#{prefix}/")
        end

        # Git metadata bytes as stripped UTF-8, independent of the locale.
        def text(bytes)
          bytes.to_s.dup.force_encoding(Encoding::UTF_8).scrub('').strip
        end

        def common_dir(dir)
          pointer = File.join(dir, 'commondir')
          File.file?(pointer) ? File.expand_path(text(File.binread(pointer, 4096)), dir) : dir
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
      # @param client_root_map [Array<Array(String, String)>] bind mounts
      #   between the client's file system and this one; empty when the client
      #   root is read here as given
      # @param client_root_map_error [String, nil] why the map was refused
      # @param client_identity [Hash, nil] what the client's checkout is, as a
      #   launch that cannot read it declared ({.parse_client_identity})
      def initialize(index_dir:, marker:, manifest:, cwd:, build:, declared_client_root: nil, client_root_map: [],
                     client_root_map_error: nil, client_identity: nil)
        @index_dir = index_dir.to_s
        @marker = marker || Woods::Generation::UNPUBLISHED
        @manifest = manifest.is_a?(Hash) ? manifest : {}
        @build = build
        @declared_client_root = declared_client_root
        @client_root_map_error = client_root_map_error
        @client_identity = client_identity
        mapped = !declared_client_root.nil? && !client_root_map.empty?
        @mapped_client_root, @client_root_map_entry =
          (self.class.map_client_root(declared_client_root, client_root_map) if mapped)
        @client_root_unmapped = mapped && @mapped_client_root.nil?
        # A map entry claims the mount holds the session's checkout; a derived
        # path missing here shows the claim does not hold for this session.
        @client_root_mapped_missing = !@mapped_client_root.nil? && !File.exist?(@mapped_client_root)
        @cwd = @mapped_client_root || (@client_root_unmapped ? nil : cwd)
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

      # @return [String, nil] the client checkout's branch, read from it, or
      #   as declared when it cannot be read here
      def client_branch
        return @client_branch if defined?(@client_branch)

        @client_branch = client_root ? self.class.checkout_branch(client_root) : @client_identity&.dig(:branch)
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
        when 'different_checkout', 'client_root_unmapped', 'client_root_mapped_missing', 'client_identity_differs'
          false
        end
      end

      # @return [String] same_checkout, different_checkout, client_root_unmapped,
      #   client_root_mapped_missing, client_identity_differs, root_not_recorded,
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
          client_root_map_entry: @client_root_map_entry&.join('='), client_root_mapped_to: @mapped_client_root,
          client_identity: @client_identity,
          client_branch: client_branch, branch_matches: branch_matches,
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
        if match_reason == 'client_identity_differs'
          return "The client root #{@declared_client_root} is not visible here, and the client's checkout is " \
                 "#{describe_identity(@client_identity)}, not the checkout this server serves, #{recorded_checkout} " \
                 "(#{describe_identity(served_identity)}). Map the mount that holds it (#{CLIENT_ROOT_MAP_ENV}), " \
                 "or pass --allow-mismatch (#{ALLOW_ENV}=1) to serve this index anyway."
        end
        if @client_root_mapped_missing
          return "The client root #{@declared_client_root} maps to #{@mapped_client_root} through " \
                 "#{@client_root_map_entry.join('=')}, but that path does not exist here: the mount does not hold " \
                 "the session's checkout, so this index cannot be its own. Fix the map, or pass --allow-mismatch " \
                 "(#{ALLOW_ENV}=1) to serve this index anyway."
        end
        if @client_root_unmapped
          return "The client root #{@declared_client_root} is under no --client-root-map prefix " \
                 "(#{CLIENT_ROOT_MAP_ENV}): no mount covers it, so the session's checkout is not visible to this " \
                 'server and this index cannot be its own. Map the mount that holds it, or pass --allow-mismatch ' \
                 "(#{ALLOW_ENV}=1) to serve this index anyway."
        end

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
        if match_reason == 'client_identity_differs'
          return "The client's checkout is #{describe_identity(@client_identity)}, not #{recorded_checkout}; " \
                 "answers are for #{recorded_checkout}, not the session's checkout."
        end
        if @client_root_unmapped || @client_root_mapped_missing
          why = if @client_root_unmapped
                  'is under no --client-root-map prefix'
                else
                  "maps to #{@mapped_client_root}, which does not exist here"
                end
          return "The client root #{@declared_client_root} #{why}; answers are for " \
                 "#{recorded_checkout || @index_dir}, not the session's checkout."
        end

        "This index describes #{recorded_checkout}, not the launch checkout #{client_root}; answers are for that " \
          'checkout.'
      end

      # One line for either side, or both, that cannot be determined.
      def unknown_checkout_warning
        if recorded_checkout && !@declared_client_root
          return "The launch directory #{@cwd} is not inside a git checkout, so this index was not compared with " \
                 "the client's checkout (pass --client-root to compare them)."
        end

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

        if @client_root_map_error
          return "the client's checkout is unknown: #{CLIENT_ROOT_MAP_ENV} is malformed (#{@client_root_map_error})"
        end
        if @mapped_client_root
          return "the client's checkout is unknown: the client root #{@declared_client_root}, mapped to " \
                 "#{@mapped_client_root} through #{@client_root_map_entry.join('=')}, is not inside a git checkout here"
        end

        "the client's checkout is unknown: the client root #{@declared_client_root} does not resolve to a git " \
          'checkout here (pass --client-root-map with the mount that makes it visible)'
      end

      # A client root read through a --client-root-map entry that matched: the
      # index's checkout is the one the client names by that host path.
      def mapped_match?
        @mapped_client_root && client_matches == true
      end

      def served_name
        mapped_match? ? File.basename(host_checkout) : root_name
      end

      def served_location
        return "#{host_checkout}, mapped to #{recorded_checkout}" if mapped_match?

        recorded_checkout || recorded_root
      end

      # The client's checkout as the client names it: the declared client root
      # less the path from the checkout down to the session's directory.
      def host_checkout
        below = Pathname.new(File.realpath(@mapped_client_root)).relative_path_from(Pathname.new(client_root)).to_s
        return @declared_client_root if below == '.'

        host = Pathname.new(self.class.send(:normalize_prefix, @declared_client_root))
        below.split('/').size.times { host = host.dirname }
        host.to_s
      rescue SystemCallError, ArgumentError
        @declared_client_root
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
        # Before the index side: whatever this index is, it cannot be the
        # session's when no mount covers the session's checkout.
        return 'client_root_unmapped' if @client_root_unmapped
        return 'client_root_mapped_missing' if @client_root_mapped_missing

        unless recorded_checkout
          return recorded_root ? 'recorded_root_unreachable' : 'root_not_recorded'
        end

        unless client_root
          return 'client_outside_checkout' unless @declared_client_root

          return identity_differs? ? 'client_identity_differs' : 'client_root_unresolved'
        end

        # Compare checkouts, not paths: a worktree nested inside another
        # checkout is still its own checkout.
        recorded_checkout == client_root ? 'same_checkout' : 'different_checkout'
      end

      # The declared client identity against the served checkout's: a known
      # field that differs on both sides. Agreement proves nothing more than
      # the warning already says.
      def identity_differs?
        served = served_identity
        return false unless @client_identity && served
        return true unless @client_identity[:worktree] == served[:worktree]

        %i[head branch].any? do |field|
          @client_identity[field] && served[field] && @client_identity[field] != served[field]
        end
      end

      def served_identity
        return @served_identity if defined?(@served_identity)

        @served_identity = self.class.checkout_identity(recorded_checkout)
      end

      def describe_identity(identity)
        "a #{identity[:worktree]} checkout#{" on #{identity[:branch]}" if identity[:branch]}" \
          "#{" at #{BuildIdentity.short(identity[:head])}" if identity[:head]}"
      end

      def string(value)
        value.is_a?(String) && !value.empty? ? value : nil
      end
    end
  end
end
