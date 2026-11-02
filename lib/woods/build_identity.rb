# frozen_string_literal: true

require 'open3'
require_relative 'version'
require_relative 'build_comparison'

module Woods
  # Which Woods build is running, and whether it is the build that wrote an
  # index.
  #
  # A version string alone cannot tell builds apart: every build pinned to a
  # git revision between two releases reports the same `x.y.z.alpha`. So a
  # build loaded from git also carries its revision: the locked revision of a
  # Bundler git source, or `git rev-parse HEAD` of a checkout whose root is the
  # gem root (a path gem or a development checkout). A released gem has no
  # revision, and comparison falls back to the version string, as before.
  #
  # The extractor records {#revision} and {#dirty} in the manifest; readers
  # compare them with {.compare}. Detection is lazy: nothing runs `git` until
  # a revision is asked for, and a released gem never does.
  #
  # Loaded without the rest of the library by `woods-mcp-start`, so it
  # requires nothing beyond the standard library and the version constant.
  class BuildIdentity
    # The directory this file's gem was loaded from.
    GEM_ROOT = File.expand_path('../..', __dir__)

    # Clear repository overrides an extraction may carry (WOODS_GIT_DIR is
    # mapped onto these), so `git -C <gem root>` asks the gem's own
    # repository, never the application's.
    GIT_ENV = { 'GIT_DIR' => nil, 'GIT_WORK_TREE' => nil, 'GIT_INDEX_FILE' => nil,
                'GIT_COMMON_DIR' => nil, 'GIT_OBJECT_DIRECTORY' => nil }.freeze

    # Paths whose uncommitted changes make a checkout build dirty.
    BUILD_PATHS = %w[lib exe woods.gemspec].freeze

    SHA = /\A\h{40,64}\z/

    class << self
      # @return [BuildIdentity] this process's build, memoized
      def current
        @current ||= new
      end

      # Forget the memoized build (specs).
      def reset!
        @current = nil
      end

      # Compare the writer recorded in +manifest+ with +reader+.
      #
      # @param manifest [Hash, nil] the published manifest
      # @param reader [BuildIdentity]
      # @return [BuildComparison]
      def compare(manifest, reader: current)
        BuildComparison.call(manifest, reader: reader)
      end

      # @return [String, nil] the first 12 characters of a revision
      def short(revision)
        revision&.slice(0, 12)
      end
    end

    # @param spec [Gem::Specification, nil] the loaded Woods spec
    # @param root [String] the gem root the running code came from
    def initialize(spec: Gem.loaded_specs['woods'], root: GEM_ROOT)
      @spec = spec
      @root = root
    end

    # @return [String]
    def version
      Woods::VERSION
    end

    # @return [String, nil] full git revision; nil for a released gem
    def revision
      detected[0]
    end

    # @return [Boolean, nil] uncommitted build changes; nil without a revision
    def dirty
      detected[1]
    end

    # @return [Hash] manifest fields
    def manifest_fields
      { woods_revision: revision, woods_revision_dirty: dirty }
    end

    private

    def detected
      @detected ||= bundler_git_revision || checkout_revision || [nil, nil]
    end

    # A Bundler git source installs a checkout without `.git`; the lockfile
    # revision names it. Bundler leaves that checkout as fetched.
    def bundler_git_revision
      source = bundler_git_source
      revision = source.options['revision'] if source.respond_to?(:options)
      revision.is_a?(String) && SHA.match?(revision) ? [revision, false] : nil
    rescue StandardError
      nil
    end

    def bundler_git_source
      return unless defined?(Bundler::Source::Git) && @spec.respond_to?(:source)

      @spec.source if @spec.source.is_a?(Bundler::Source::Git)
    end

    # Only a checkout rooted at the gem root counts: a released gem vendored
    # inside an application's repository must not report the application's
    # revision.
    def checkout_revision
      return unless File.exist?(File.join(@root, '.git'))

      revision = git('rev-parse', 'HEAD')&.strip
      return unless revision && SHA.match?(revision)

      status = git('status', '--porcelain', '--', *BUILD_PATHS)
      [revision, status.nil? ? nil : !status.empty?]
    end

    def git(*args)
      output, _errors, status = Open3.capture3(GIT_ENV, 'git', '-C', @root, *args)
      status.success? ? output : nil
    rescue SystemCallError
      nil
    end
  end
end
