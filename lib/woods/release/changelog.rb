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
    #
    # A final release also absorbs every prerelease section of its own base
    # version, so the notes a user reads for `2.0.0` are the whole story rather
    # than three fragments they have to stitch together. That makes an empty
    # Unreleased section legitimate for a final release cut straight from an rc,
    # and still a refusal for a prerelease, which has nothing new to publish.
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
      # blocks over a cycle releases as one. A final release folds its own
      # prereleases in first, oldest first, so entries keep the order they were
      # written in. An empty `## [Unreleased]` is left behind for the next cycle.
      #
      # @return [String] the rewritten changelog
      def fold(source, version:, date: Time.now.utc.to_date)
        if source.match?(/^## \[#{Regexp.escape(version)}\] - /)
          raise DuplicateRelease, "CHANGELOG.md already has a dated heading for #{version}"
        end

        state = VersionState.parse(version)
        head, body, tail = split_unreleased(source)
        superseded = state.final? ? superseded_prereleases(tail, state) : []
        blocks = merge_blocks(superseded.flat_map { |section| section.fetch(:blocks) } + parse_blocks(body))
        raise EmptyUnreleasedSection, empty_message(state) if blocks.empty?

        "#{head}#{UNRELEASED_HEADING}\n\n## [#{version}] - #{date.strftime('%Y-%m-%d')}\n\n" \
          "#{render_blocks(blocks)}#{without_sections(tail, superseded)}"
      end

      # @api private
      def empty_message(state)
        if state.final?
          "the Unreleased section is empty and no #{state.base} prerelease section exists; nothing to release"
        else
          'the Unreleased section is empty; nothing to release'
        end
      end

      # Every dated section that is a prerelease of the release being cut. A
      # prerelease of another base version (a 1.7.0 beta still in the file) is
      # left where it is.
      #
      # @api private
      def superseded_prereleases(tail, state)
        split_sections(tail).select { |section| supersedes?(section.fetch(:version), state) }
                            .sort_by { |section| Gem::Version.new(section.fetch(:version)) }
                            .map { |section| section.merge(blocks: parse_blocks(section.fetch(:body))) }
      end

      # @api private
      def supersedes?(version, state)
        return false unless version

        candidate = begin
          VersionState.parse(version)
        rescue VersionState::InvalidVersion
          nil
        end
        candidate&.prerelease? && candidate.base == state.base
      end

      # @api private
      def split_sections(tail)
        tail.split(/^(?=## )/).reject(&:empty?).map do |chunk|
          heading, body = chunk.split("\n", 2)
          { source: chunk, heading: heading, body: body.to_s, version: RELEASE_HEADING.match(heading)&.[](:version) }
        end
      end

      # @api private
      def without_sections(tail, removed)
        return tail if removed.empty?

        sources = removed.map { |section| section.fetch(:source) }
        split_sections(tail).reject { |section| sources.include?(section.fetch(:source)) }
                            .map { |section| section.fetch(:source) }.join
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
      #
      # Joined with a single newline, not a blank line: each block's content
      # is already a tight bullet list, and a blank line between two merged
      # occurrences of the same heading would split one list into two
      # paragraphs instead of continuing it.
      def merge_blocks(blocks)
        blocks.reject { |_heading, content| content.empty? }
              .group_by(&:first)
              .map { |heading, group| [heading, group.map(&:last).join("\n")] }
      end

      # @api private
      def render_blocks(blocks)
        blocks.map { |heading, content| "### #{heading}\n\n#{content}\n\n" }.join
      end
    end
  end
end
