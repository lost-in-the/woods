# frozen_string_literal: true

require 'date'

require_relative 'version_state'

module Woods
  module Release
    # Reads and rewrites CHANGELOG.md for the release flow.
    #
    # Feature work only ever touches `## [Unreleased]`. A release folds that
    # section into `## [<VERSION>] - <date>` with one block per `###` heading and
    # leaves an empty `## [Unreleased]` behind for the next cycle.
    module Changelog
      # Raised when CHANGELOG.md has no `## [Unreleased]` section to fold.
      class MissingUnreleasedSection < Error; end

      # Raised when the Unreleased section holds no entries.
      class EmptyUnreleasedSection < Error; end

      # Raised when an entry sits directly under `## [Unreleased]` rather than
      # under a `###` heading, so it has no block to fold into.
      class UnclassifiedEntries < Error; end

      # Raised when the target version already has a dated heading.
      class DuplicateRelease < Error; end

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

      # Folds `## [Unreleased]` into `## [<version>] - <date>`.
      #
      # Entries are grouped into one block per `###` heading, in the order the
      # headings first appear, so a section that collected two `### Added`
      # blocks over a cycle releases as one. An empty `## [Unreleased]` is left
      # behind for the next cycle.
      #
      # @return [String] the rewritten changelog
      def fold(source, version:, date: Date.today)
        if source.match?(/^## \[#{Regexp.escape(version)}\] - /)
          raise DuplicateRelease, "CHANGELOG.md already has a dated heading for #{version}"
        end

        head, body, tail = split_unreleased(source)
        blocks = merge_blocks(parse_blocks(body))
        raise EmptyUnreleasedSection, 'the Unreleased section is empty; nothing to release' if blocks.empty?

        "#{head}#{UNRELEASED_HEADING}\n\n## [#{version}] - #{date.strftime('%Y-%m-%d')}\n\n" \
          "#{render_blocks(blocks)}#{tail}"
      end

      # @api private
      def split_unreleased(source)
        match = /^#{Regexp.escape(UNRELEASED_HEADING)}\n/.match(source)
        raise MissingUnreleasedSection, "CHANGELOG.md has no #{UNRELEASED_HEADING} section" unless match

        rest = match.post_match
        boundary = rest.index(/^## /)
        [match.pre_match, boundary ? rest[0...boundary] : rest, boundary ? rest[boundary..] : '']
      end

      # @api private
      def parse_blocks(body)
        preamble, *sections = body.split(/^(?=### )/)
        stray = preamble.to_s.strip
        raise UnclassifiedEntries, "entries sit outside a ### heading in Unreleased:\n#{stray}" unless stray.empty?

        sections.map do |section|
          heading, content = section.split("\n", 2)
          [heading.sub(/\A### /, ''), content.to_s.strip]
        end
      end

      # @api private
      def merge_blocks(blocks)
        blocks.reject { |_heading, content| content.empty? }
              .group_by(&:first)
              .map { |heading, group| [heading, group.map(&:last).join("\n\n")] }
      end

      # @api private
      def render_blocks(blocks)
        blocks.map { |heading, content| "### #{heading}\n\n#{content}\n\n" }.join
      end
    end
  end
end
