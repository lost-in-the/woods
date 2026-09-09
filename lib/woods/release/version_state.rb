# frozen_string_literal: true

require_relative '../release'

module Woods
  module Release
    # The release state of the tree, derived from `Woods::VERSION` alone.
    #
    # `main` carries `X.Y.Z.alpha` between releases: a development marker that
    # is never tagged and never published. A release commit sets
    # `X.Y.Z.betaN`, `X.Y.Z.rcN`, or `X.Y.Z` and is tagged `v<VERSION>`. After a
    # final release, `release:reopen` sets the next `.alpha`.
    class VersionState # rubocop:disable Metrics/ClassLength
      # Raised when a string is not one of the four version shapes above.
      class InvalidVersion < Error; end

      # Raised when a requested state change is not one the flow allows.
      class InvalidTransition < Error; end

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

        # Guards `release:prepare`. A release is always cut from the alpha or a
        # previous prerelease of the same base version, and always moves forward.
        def validate_prepare!(current, target)
          if target.alpha?
            raise InvalidTransition,
                  "#{target} is an alpha development marker; use release:reopen to move main to the next alpha"
          end
          if current.final?
            raise InvalidTransition,
                  "current version #{current} is already released; run release:reopen before preparing another release"
          end

          validate_same_base!(current, target)
          validate_forward!(current, target)
        end

        # Guards `release:reopen`. Development only reopens from a final release
        # into a strictly later alpha.
        def validate_reopen!(current, target)
          unless target.alpha?
            raise InvalidTransition, "#{target} is not an alpha development marker; release:reopen sets X.Y.Z.alpha"
          end
          unless current.final?
            raise InvalidTransition,
                  "current version #{current} is not a final release; only a released tree reopens for development"
          end

          validate_forward!(current, target)
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

        def validate_same_base!(current, target)
          return if current.base == target.base

          raise InvalidTransition,
                "#{target} does not release #{current}: main is developing #{current.base}, " \
                "so the next release must be a #{current.base} beta, rc, or final"
        end

        def validate_forward!(current, target)
          return if target.gem_version > current.gem_version

          raise InvalidTransition, "#{target} does not come after the current version #{current}"
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
