# frozen_string_literal: true

require_relative 'changelog'
require_relative 'version_state'

module Woods
  module Release
    # The `release-state` fences: the documentation claims that expire when the
    # version state changes.
    #
    # Two kinds of fence:
    #
    # * `:note` fences hold a whole block that only exists in some states. Their
    #   body is generated from the state and is empty once the version is final.
    # * `:ref` fences hold ordinary prose whose repository links must point at
    #   the tree the reader is on. Only the git ref inside a woods repository URL
    #   is rewritten; the prose is left alone.
    module Notes # rubocop:disable Metrics/ModuleLength
      class MissingFence < Error; end

      MARKER = 'release-state'
      REPOSITORY_URL = 'https://github.com/lost-in-the/woods'

      FENCES = [
        { path: 'README.md', id: 'version-banner', kind: :note, builder: :version_banner },
        { path: 'CONTRIBUTING.md', id: 'contributing-intro', kind: :ref },
        { path: 'CONTRIBUTING.md', id: 'contributing-architecture', kind: :ref },
        # `target` is the version the guide is about, not the version the tree
        # is on. The guide covers the 1.x to 2.0 migration, so its note has
        # nothing to say once development moves past 2.0.0.
        { path: 'docs/UPGRADING_TO_2.md', id: 'upgrade-availability', kind: :note,
          builder: :upgrade_availability, target: '2.0.0' }
      ].freeze

      BRANCH_PARAGRAPH = '> `main` is the development branch and can run ahead of the latest published gem. ' \
                         'The gem badge above shows the latest published version; documentation for a ' \
                         'published version lives on its tag.'

      REPOSITORY_REF = %r{(#{Regexp.escape(REPOSITORY_URL)}/(?:blob|tree)/)([^/\s)]+)(/)}

      module_function

      # @return [Array<String>] every fence whose content disagrees with VERSION
      def mismatches(root:, version:)
        state = VersionState.parse(version)
        previous = previous_stable_version(root)

        FENCES.filter_map do |fence|
          body = read_body(root, fence)
          next "#{fence.fetch(:path)}: no #{MARKER}:#{fence.fetch(:id)} fence" if body.nil?

          mismatch_for(fence, body, state, previous)
        end
      end

      # The new source of every document whose fences change, computed without
      # touching the tree so a caller can validate everything before writing.
      #
      # `changelog:` lets a release pass the folded changelog it has not written
      # yet, so the banner names the same published gem the committed tree will.
      #
      # @return [Hash{String => String}] repository-relative path to new source
      def rewrites(root:, version:, changelog: nil)
        state = VersionState.parse(version)
        previous = Changelog.latest_stable_version(changelog || read(root, 'CHANGELOG.md'))

        FENCES.group_by { |fence| fence.fetch(:path) }.filter_map do |path, fences|
          original = read(root, path)
          updated = fences.reduce(original) do |source, fence|
            body = fence_body(source, fence)
            raise MissingFence, "#{path}: no #{MARKER}:#{fence.fetch(:id)} fence" if body.nil?

            replace_body(source, fence, expected_body(fence, body, state, previous))
          end
          [path, updated] unless updated == original
        end.to_h
      end

      # Rewrites every fence into the state `version` declares.
      #
      # @return [Array<String>] the repository-relative paths that changed
      def apply!(root:, version:)
        rewrites(root: root, version: version).map do |path, source|
          File.write(File.join(root, path), source)
          path
        end
      end

      # @return [String, nil] the fence body, or nil when the fence is absent
      def read_body(root, fence)
        fence_body(read(root, fence.fetch(:path)), fence)
      end

      def read(root, path)
        File.read(File.join(root, path), encoding: Encoding::UTF_8)
      end

      # The document with every fence (markers and bodies) removed, so a spec can
      # assert that no state-dependent claim escaped into unmanaged prose.
      #
      # @return [String]
      def source_outside_fences(root, path)
        opening = Regexp.escape("<!-- #{MARKER}:")
        closing = Regexp.escape("<!-- #{MARKER}:end -->")
        read(root, path).gsub(/^#{opening}[a-z][a-z-]* -->\n.*?^#{closing}\n/m, '')
      end

      def previous_stable_version(root)
        Changelog.latest_stable_version(read(root, 'CHANGELOG.md'))
      end

      def fence_pattern(fence)
        opening = Regexp.escape("<!-- #{MARKER}:#{fence.fetch(:id)} -->")
        closing = Regexp.escape("<!-- #{MARKER}:end -->")
        /^#{opening}\n(?<body>.*?)^#{closing}\n/m
      end

      def fence_body(source, fence)
        source[fence_pattern(fence), :body]
      end

      def replace_body(source, fence, body)
        source.sub(fence_pattern(fence)) do
          "<!-- #{MARKER}:#{fence.fetch(:id)} -->\n#{body}<!-- #{MARKER}:end -->\n"
        end
      end

      def expected_body(fence, body, state, previous)
        case fence.fetch(:kind)
        when :note then public_send(fence.fetch(:builder), state, previous, fence)
        when :ref
          body.gsub(REPOSITORY_REF) { "#{Regexp.last_match(1)}#{state.release_ref}#{Regexp.last_match(3)}" }
        end
      end

      def mismatch_for(fence, body, state, previous)
        expected = expected_body(fence, body, state, previous)
        return if body == expected

        case fence.fetch(:kind)
        when :ref
          "#{fence.fetch(:path)}: #{MARKER}:#{fence.fetch(:id)} links do not point at #{state.release_ref}"
        else
          "#{fence.fetch(:path)}: #{MARKER}:#{fence.fetch(:id)} does not match the #{state.state} state of #{state}"
        end
      end

      # The README version banner. It owns every version claim in the README, so
      # nothing above it goes stale at a release. Empty once the documented
      # version is released: the gem badge is then the whole story.
      def version_banner(state, previous, _fence = nil)
        return '' if state.final?

        blocks = [
          documents_paragraph(state, previous),
          BRANCH_PARAGRAPH,
          version_table(state, previous),
          "> #{banner_constraint(state, previous)}"
        ]
        "#{blocks.join("\n>\n")}\n"
      end

      def documents_paragraph(state, previous)
        documented = state.documented_version
        sentences = ["> **This tree documents version #{documented}.**"]
        sentences << upgrade_sentence(documented, previous) if major_bump?(documented, previous)
        sentences << 'The full history is in the [CHANGELOG](CHANGELOG.md).'
        sentences.join(' ')
      end

      def upgrade_sentence(documented, previous)
        "It is a major update from #{previous.split('.').first}.x: read " \
          "[what changed and how to upgrade](docs/UPGRADING_TO_#{documented.split('.').first}.md) " \
          'before updating.'
      end

      def major_bump?(documented, previous)
        return false unless previous

        documented.split('.').first != previous.split('.').first
      end

      def version_table(state, previous)
        rows = ["> | Documented here | **#{state.documented_version}**, unreleased | this README and the " \
                '[documentation index](docs/README.md) |']
        rows << "> | Latest prerelease | **#{state}** | #{tag_link(state.tag)} |" if state.prerelease?
        rows << "> | Latest published gem | **#{previous}** | #{tag_link("v#{previous}")} |" if previous

        ["> ### #{banner_heading(state)}", '>', '> | Line | Version | Documentation |', '> |---|---|---|', *rows]
          .join("\n")
      end

      def banner_heading(state)
        if state.prerelease?
          "Version: #{state} is published as a prerelease; `main` documents #{state.documented_version}"
        else
          "Version: `main` documents #{state.documented_version}, which is not released yet"
        end
      end

      def banner_constraint(state, previous)
        released = previous ? " The released constraint stays `gem \"woods\", \"#{approximate(previous)}\"`." : ''

        if state.prerelease?
          "RubyGems treats #{state} as a prerelease, so `gem \"woods\", \"#{state.approximate_constraint}\"` does " \
            "not resolve it. Install it explicitly with `gem \"woods\", \"#{state}\"`.#{released}"
        else
          "Everything below describes #{state.documented_version}. `gem \"woods\", " \
            "\"#{state.approximate_constraint}\"` does not resolve from RubyGems until " \
            "#{state.documented_version} is published.#{released}"
        end
      end

      # The upgrade guide's availability note.
      #
      # The guide is about one target version, not about whatever `main` is
      # developing, so the note is empty once that target ships or once
      # development moves past it.
      def upgrade_availability(state, _previous, fence)
        target = fence.fetch(:target)
        return '' unless state.documented_version == target
        return '' if state.final?

        if state.prerelease?
          <<~MARKDOWN
            > RubyGems lists #{state} as a prerelease. Pin it explicitly with
            > `gem "woods", "#{state}"`; `#{state.approximate_constraint}` resolves only once
            > #{target} is published.
          MARKDOWN
        else
          <<~MARKDOWN
            > Run the published-gem upgrade only after RubyGems lists #{target}. Until then,
            > this guide supports planning and validation against a source checkout.
          MARKDOWN
        end
      end

      def approximate(version)
        major, minor, = version.split('.')
        "~> #{major}.#{minor}"
      end

      def tag_link(tag)
        "[the #{tag} tag](#{REPOSITORY_URL}/tree/#{tag})"
      end
    end
  end
end
