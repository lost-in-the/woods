# frozen_string_literal: true

require 'pathname'
require 'json'
require 'fileutils'
require 'tempfile'

module Woods
  # Whole Value for the on-disk artifact layout under +output_dir+.
  #
  # Centralises all path derivation and atomic write operations so that no
  # caller ever assembles paths by hand. The +dumps/latest+ pointer file
  # provides cross-artifact atomicity: consumers always read the pointer
  # first; the pointer is flipped last, after the dump directory is fully
  # fsynced.
  #
  # @example Basic usage
  #   artifact = Woods::IndexArtifact.new(output_dir)
  #   return if artifact.fresh?
  #   config = artifact.read_config
  #   dump_dir = artifact.latest_dump_path
  #
  class IndexArtifact
    # @param output_dir [String, Pathname] path to the extraction output directory
    def initialize(output_dir)
      @root = Pathname.new(output_dir.to_s)
    end

    # The extraction output directory root.
    #
    # @return [Pathname]
    def output_dir
      @root
    end

    # Path to the resolved config snapshot written by the embed run.
    #
    # @return [Pathname]
    def config_path
      @root.join('woods.json')
    end

    # Root of the per-run dump directories.
    #
    # @return [Pathname]
    def dumps_root
      @root.join('dumps')
    end

    # Path to the +dumps/latest+ pointer file (may not exist yet).
    #
    # @return [Pathname]
    def latest_pointer_path
      dumps_root.join('latest')
    end

    # Returns true when the artifact has never been populated — +woods.json+
    # is absent AND the +dumps/latest+ pointer does not exist.
    #
    # Once either file is present the artifact is considered non-fresh and the
    # Bootstrapper loads from it. A fresh artifact boots in pattern-only mode by
    # default, raising {Woods::MCP::MissingArtifact} only under WOODS_REQUIRE_INDEX=1.
    #
    # @return [Boolean]
    def fresh?
      !config_path.exist? && !latest_pointer_path.exist?
    end

    # Path to the latest complete dump directory, or +nil+.
    #
    # Returns +nil+ if the pointer file does not exist, if the pointer content
    # is blank, or if the directory it names no longer exists (stale pointer).
    #
    # @return [Pathname, nil]
    def latest_dump_path
      return nil unless latest_pointer_path.exist?

      dirname = latest_pointer_path.read.strip
      return nil if dirname.empty?

      dir = dumps_root.join(dirname)
      dir.exist? ? dir : nil
    end

    # Reads and parses +woods.json+, returning the raw hash.
    #
    # Returns +nil+ when the file does not exist. Schema-version validation
    # is the caller's responsibility (typically {Woods::ResolvedConfig.from_hash}).
    #
    # @return [Hash, nil]
    def read_config
      return nil unless config_path.exist?

      JSON.parse(config_path.read)
    end

    # Creates a new timestamped dump directory and returns its path.
    #
    # The directory is created immediately so callers can begin writing into
    # it. +dumps_root+ is created on demand. Directory names use dashes in
    # place of colons for filesystem compatibility (+%H-%M-%SZ+ not
    # +%H:%M:%SZ+).
    #
    # @param now [Time] timestamp to use for the directory name (default: UTC now)
    # @return [Pathname]
    # @raise [Errno::EEXIST] if the target directory already exists
    def new_dump_dir(now: Time.now.utc)
      dirname = now.strftime('%Y-%m-%dT%H-%M-%SZ')
      dir = dumps_root.join(dirname)
      FileUtils.mkdir_p(dumps_root)
      Dir.mkdir(dir.to_s)
      dir
    end

    # Atomically flips the +latest+ pointer to the given dump directory.
    #
    # Uses a temp file + +File.rename+ so a crash mid-flip leaves the previous
    # pointer intact. +dump_dir+ must exist and resolve to a path inside
    # +dumps_root+.
    #
    # @param dump_dir [Pathname, String] completed dump directory to promote
    # @return [void]
    # @raise [ArgumentError] if +dump_dir+ does not exist or is outside +dumps_root+
    def promote(dump_dir)
      target = Pathname.new(dump_dir.to_s)
      root_real = dumps_root.expand_path.to_s
      target_real = target.exist? ? target.realpath.to_s : ''
      # Resolve symlinks on both sides before comparing (handles macOS /tmp → /private/var)
      root_resolved = Pathname.new(root_real).exist? ? Pathname.new(root_real).realpath.to_s : root_real
      unless target.exist? && target_real.start_with?(root_resolved)
        raise ArgumentError,
              'dump_dir must exist inside dumps_root. ' \
              "Got: #{dump_dir.inspect}, dumps_root: #{dumps_root}"
      end

      atomic_write(latest_pointer_path, target.basename.to_s)
    end

    # Atomically writes a resolved config hash as +woods.json+.
    #
    # Accepts either a +ResolvedConfig+ (responds to +#to_snapshot_json+) or
    # a plain +Hash+. When +#to_snapshot_json+ returns a +Hash+, it is
    # serialized to JSON automatically — callers need not pre-serialize.
    #
    # @param resolved_config_hash [#to_snapshot_json, Hash]
    # @return [void]
    def write_config(resolved_config_hash)
      raw = if resolved_config_hash.respond_to?(:to_snapshot_json)
              resolved_config_hash.to_snapshot_json
            else
              resolved_config_hash
            end
      json = raw.is_a?(String) ? raw : JSON.pretty_generate(raw)
      atomic_write(config_path, json)
    end

    private

    def atomic_write(path, content)
      FileUtils.mkdir_p(path.dirname)
      tmp = Tempfile.new('.woods-', path.dirname.to_s)
      tmp.write(content)
      tmp.flush
      tmp.fsync
      tmp.close
      File.rename(tmp.path, path.to_s)
    rescue StandardError
      tmp&.close
      tmp&.unlink
      raise
    end
  end
end
