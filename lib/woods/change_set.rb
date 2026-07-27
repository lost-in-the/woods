# frozen_string_literal: true

require 'pathname'

module Woods
  # A normalized set of changed paths, shared by every entry point that has
  # to answer "what changed?".
  #
  # Today that is the git-diff-driven `woods:incremental` rake task; a
  # file-watching daemon (#164, phase 2) would feed the same object from FS
  # events. Two code paths computing "what changed" independently is exactly
  # how a watcher and a CI chain drift apart, so the normalization —
  # absolutizing, de-duplicating, and splitting present-from-vanished — lives
  # here rather than in either caller.
  #
  # Paths are held absolute (matching how {DependencyGraph} registers file
  # paths) and exposed relative on demand (matching how {PathDispatcher}
  # rules are written).
  #
  # @example
  #   cs = Woods::ChangeSet.new(paths: %w[app/models/user.rb app/models/gone.rb], root: Rails.root)
  #   cs.existing_paths # => ["/app/app/models/user.rb"]
  #   cs.missing_paths  # => ["/app/app/models/gone.rb"]
  #
  class ChangeSet
    # @return [Pathname] the application root paths are resolved against
    attr_reader :root

    # @param paths [Array<String>] changed paths, absolute or root-relative
    # @param root [String, Pathname] application root (usually Rails.root)
    def initialize(paths:, root:)
      @root = Pathname.new(root.to_s)
      @absolute_paths = Array(paths).filter_map { |p| absolutize(p) }.uniq.freeze
    end

    # @return [Array<String>] every changed path, absolute
    attr_reader :absolute_paths

    # @return [Array<String>] every changed path, relative to {#root}
    def relative_paths
      @relative_paths ||= @absolute_paths.map { |p| relativize(p) }.freeze
    end

    # Changed paths that still exist on disk (created or modified).
    #
    # @return [Array<String>] absolute paths
    def existing_paths
      @existing_paths ||= @absolute_paths.select { |p| File.exist?(p) }.freeze
    end

    # Changed paths that no longer exist (deleted, or the old side of a
    # rename — git's `--no-renames` semantics, which is what the deletion
    # sweep expects).
    #
    # @return [Array<String>] absolute paths
    def missing_paths
      @missing_paths ||= (@absolute_paths - existing_paths).freeze
    end

    # @return [Boolean] true when nothing changed
    def empty?
      @absolute_paths.empty?
    end

    # @return [Integer] number of changed paths
    def size
      @absolute_paths.size
    end

    # Convert an absolute path back to a root-relative one.
    #
    # @param path [String] absolute path
    # @return [String] root-relative path, or the input if outside {#root}
    def relativize(path)
      prefix = "#{@root}/"
      path.start_with?(prefix) ? path.delete_prefix(prefix) : path
    end

    private

    def absolutize(path)
      str = path.to_s.strip
      return nil if str.empty?

      Pathname.new(str).absolute? ? str : @root.join(str).to_s
    end
  end
end
