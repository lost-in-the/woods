# frozen_string_literal: true

require_relative 'version_state'

module Woods
  module Release
    # Reads and rewrites CHANGELOG.md for the release flow.
    #
    # Feature work only ever touches `## [Unreleased]`. A release folds that
    # section into `## [<VERSION>] - <date>` with one block per `###` heading and
    # leaves an empty `## [Unreleased]` behind for the next cycle.
    module Changelog
      class MissingUnreleasedSection < StandardError; end

      UNRELEASED_HEADING = '## [Unreleased]'
      RELEASE_HEADING = /^## \[(?<version>[^\]]+)\] - (?<date>\d{4}-\d{2}-\d{2})$/

      module_function

      # The newest dated heading whose version RubyGems publishes as a stable
      # release. A prerelease heading (2.0.0.beta1) is skipped, so the README
      # banner keeps naming the gem a `~> 1.6` user actually resolves.
      #
      # @return [String, nil]
      def latest_stable_version(source)
        source.scan(RELEASE_HEADING).map(&:first).find do |version|
          !Gem::Version.new(version).prerelease?
        rescue ArgumentError
          false
        end
      end

      # @return [String, nil] the newest dated heading of any kind
      def latest_released_version(source)
        source[RELEASE_HEADING, :version]
      end
    end
  end
end
