# frozen_string_literal: true

require_relative 'version_state'

module Woods
  module Release
    # Explicit legacy documentation profile. No v2 migration or inventory claims.
    module Notes
      class MissingFence < Error; end

      OPEN = '<!-- release-state:maintenance-banner -->'
      CLOSE = '<!-- release-state:end -->'
      FENCE = /^#{Regexp.escape(OPEN)}\n.*?^#{Regexp.escape(CLOSE)}\n/m

      module_function

      def rewrites(root:, version:, **_options)
        state = VersionState.parse(version)
        original = File.read(File.join(root, 'README.md'), encoding: Encoding::UTF_8)
        validate_registered_fences!(root)
        updated = replace_banner(original, state)
        original == updated ? {} : { 'README.md' => updated }
      end

      def mismatches(root:, version:)
        source = File.read(File.join(root, 'README.md'), encoding: Encoding::UTF_8)
        validate_registered_fences!(root)
        return ['README.md: missing maintenance banner'] unless source.match?(FENCE)
        return [] if source[FENCE] == banner(VersionState.parse(version))

        ['README.md: maintenance banner does not match VERSION']
      rescue MissingFence => e
        [e.message]
      end

      def replace_banner(source, state)
        return source.sub(FENCE, banner(state)) if source.match?(FENCE)

        raise MissingFence, 'README.md: missing or malformed maintenance banner'
      end

      def validate_registered_fences!(root)
        Dir.glob(File.join(root, '**', '*.md')).each do |path|
          markers = File.read(path, encoding: Encoding::UTF_8).scan(/^<!-- release-state:.*$/)
          next if markers.empty?
          next if path == File.join(root, 'README.md') && markers == [OPEN, CLOSE]

          raise MissingFence, "#{path.delete_prefix("#{root}/")}: unknown, duplicate, or malformed release-state fences"
        end
      end

      def banner(state)
        status = if state.alpha?
                   'development snapshot; never tag or publish this alpha'
                 else
                   'prepared maintenance candidate'
                 end
        <<~NOTE
          #{OPEN}
          > **Woods #{state}: #{status}.** This tree remains on the 1.6 maintenance line.
          > Preparation does not establish publication. Check [RubyGems versions](https://rubygems.org/gems/woods/versions)
          > before selecting an install version. See [maintenance release policy](CONTRIBUTING.md#maintenance-release).
          #{CLOSE}
        NOTE
      end
    end
  end
end
