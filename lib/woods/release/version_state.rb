# frozen_string_literal: true

module Woods
  # Maintainer-only release machinery, deliberately not packaged with the gem.
  # These files back `release:prepare` and `release:reopen`, which only ever run
  # from a source checkout of this repository.
  module Release
    # The release state of the tree, derived from `Woods::VERSION` alone.
    #
    # `main` carries `X.Y.Z.alpha` between releases: a development marker that
    # is never tagged and never published. A release commit sets
    # `X.Y.Z.betaN`, `X.Y.Z.rcN`, or `X.Y.Z` and is tagged `v<VERSION>`. After a
    # final release, `release:reopen` sets the next `.alpha`.
    class VersionState
      # Raised when a string is not one of the four version shapes above.
      class InvalidVersion < StandardError; end

      # Raised when a requested state change is not one the flow allows.
      class InvalidTransition < StandardError; end

      PATTERN = /\A(?<base>\d+\.\d+\.\d+)(?:\.(?<marker>alpha|beta|rc)(?<number>\d+)?)?\z/

      SHAPE_HELP = 'expected X.Y.Z.alpha, X.Y.Z.betaN, X.Y.Z.rcN, or X.Y.Z'

      attr_reader :version, :base, :marker, :number

      class << self
        # @param version [String]
        # @return [VersionState]
        # @raise [InvalidVersion]
        def parse(version)
          match = PATTERN.match(version.to_s)
          raise InvalidVersion, "#{version.inspect} is not a Woods version (#{SHAPE_HELP})" unless match

          marker = match[:marker]
          number = match[:number]
          validate_marker!(version, marker, number)
          new(version.to_s, match[:base], marker, number&.to_i)
        end

        private

        def validate_marker!(version, marker, number)
          case marker
          when nil then nil
          when 'alpha'
            raise InvalidVersion, "#{version.inspect} must be a bare .alpha marker without a number" if number
          else
            raise InvalidVersion, "#{version.inspect} must number its #{marker} (#{SHAPE_HELP})" if number.nil?
            raise InvalidVersion, "#{version.inspect} must number its #{marker} from 1" if number.to_i.zero?
          end
        end
      end

      def initialize(version, base, marker, number)
        @version = version
        @base = base
        @marker = marker
        @number = number
        freeze
      end

      # @return [Symbol] :alpha, :beta, :rc, or :final
      def state
        marker.nil? ? :final : marker.to_sym
      end

      def alpha?
        state == :alpha
      end

      def beta?
        state == :beta
      end

      def rc?
        state == :rc
      end

      # A version RubyGems publishes as a prerelease and that carries a tag.
      def prerelease?
        beta? || rc?
      end

      def final?
        state == :final
      end

      # The version the tree documents: an alpha documents its own base.
      def documented_version
        base
      end

      # The git ref that immutably identifies this tree. An alpha is never
      # tagged, so its documentation and gemspec metadata point at the branch.
      def release_ref
        alpha? ? 'main' : tag
      end

      # @raise [InvalidTransition] an alpha is never tagged
      def tag
        raise InvalidTransition, "#{version} is a development marker and is never tagged" if alpha?

        "v#{version}"
      end

      def gem_version
        Gem::Version.new(version)
      end

      # The `~> MAJOR.MINOR` constraint that resolves this line once published.
      def approximate_constraint
        major, minor, = base.split('.')
        "~> #{major}.#{minor}"
      end

      def to_s
        version
      end

      def ==(other)
        other.is_a?(VersionState) && other.version == version
      end
      alias eql? ==

      def hash
        version.hash
      end
    end
  end
end
