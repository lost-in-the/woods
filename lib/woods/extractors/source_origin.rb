# frozen_string_literal: true

require 'rbconfig'

module Woods
  module Extractors
    # Where a source file comes from, and a stable label for its location.
    #
    # Callback filters, validation options and mailer defaults are labelled
    # by the file and line that define them. An absolute path there is a
    # machine-local fact: a lambda that `dependent: :destroy` registers lives
    # in Active Record's bundle, and its path names the host checkout, the
    # bundle directory and the Ruby install, so two machines extracting the
    # same application publish different indexes (LOS-127). This module
    # turns a path into a label that depends only on what defines it:
    #
    # | Source                           | Label                                   | Origin      |
    # |----------------------------------|-----------------------------------------|-------------|
    # | under `Rails.root`               | `app/models/post.rb`                    | `app`       |
    # | an installed gem                 | `activerecord-7.1.6/lib/active_record/…` | `framework` or `gem` |
    # | a Bundler git checkout           | `rails-1a2b3c4d5e6f/activerecord/lib/…` | `framework` or `gem` |
    # | a `path:` gem outside the root   | `my_engine-0.1.0/lib/…`                 | `gem`       |
    # | the Ruby standard library        | `ruby/forwardable.rb`                   | `gem`       |
    # | anything else                    | `external/<basename>`                   | `unknown`   |
    #
    # An origin says who wrote the code, beside the callback's
    # +analysis_status+, which says whether its body could be scanned
    # (LOS-128): +app+ is the application (a concern under +app/+ included),
    # +framework+ one of the Rails gems ({RAILS_GEMS}), +gem+ any other
    # bundled gem or the standard library, and +unknown+ no source at all
    # (a native method, a string filter, an +eval+) or a file none of the
    # above claims.
    #
    # @example
    #   SourceOrigin.location('/srv/app/vendor/bundle/ruby/3.3.0/gems/activerecord-7.1.6/lib/a.rb')
    #   # => "activerecord-7.1.6/lib/a.rb"
    #   SourceOrigin.origin('/srv/app/app/models/post.rb') # => "app"
    module SourceOrigin
      # The application defines it.
      APP = 'app'
      # One of the Rails gems defines it.
      FRAMEWORK = 'framework'
      # Another bundled gem, or the Ruby standard library, defines it.
      GEM = 'gem'
      # No source location, or a file outside the application, the bundle
      # and the standard library.
      UNKNOWN = 'unknown'

      # The gems whose code counts as the framework. +rails+ is the name of a
      # git checkout of the whole framework (`/bundler/gems/rails-<sha>/`).
      RAILS_GEMS = %w[
        rails railties activerecord activemodel activesupport actionpack activestorage
        actiontext activejob actionmailer actionview actioncable actionmailbox
      ].freeze

      # The label prefix of a file that is neither the application's, a
      # gem's nor the standard library's. Only the basename follows it: the
      # directory would be a machine-local path.
      EXTERNAL = 'external'

      # The label prefix of a standard-library file.
      RUBY = 'ruby'

      # An installed gem: `…/gems/<name>-<version>/<rest>`. The last such
      # segment wins, so a bundle under the application root still resolves
      # to the gem. Paths are cut at the marker with string searches, never
      # an unanchored pattern: a path is library input, and a backtracking
      # scan over it would be polynomial in its length.
      INSTALLED_GEM = '/gems/'

      # A Bundler git checkout: `…/bundler/gems/<name>-<sha>/<rest>`.
      GIT_GEM = '/bundler/gems/'

      # A git sha suffix of a gem directory name (`rails-1a2b3c4d5e6f`),
      # matched against the text after the last dash only. A version suffix
      # (`activerecord-7.1.6`, `nokogiri-1.16.0-x86_64-linux`) starts at the
      # first dash a digit follows; see {gem_name}.
      GIT_SHA = /\A\h{7,}\z/

      # Directory segments under the application root that hold other
      # people's code.
      FOREIGN_SEGMENTS = %w[vendor node_modules].freeze

      # A source file's origin and label.
      #
      # @!attribute origin
      #   @return [String] one of {APP}, {FRAMEWORK}, {GEM}, {UNKNOWN}
      # @!attribute location
      #   @return [String, nil] the stable label, nil without a path
      Site = Struct.new(:origin, :location, keyword_init: true)

      module_function

      # Classify a path and label its location.
      #
      # @param path [String, nil] an absolute source path, as
      #   +Proc#source_location+ or +UnboundMethod#source_location+ give it
      # @param root [String, Pathname, nil] the application root
      #   (+Rails.root+ by default)
      # @return [Site]
      def site(path, root: application_root)
        return Site.new(origin: UNKNOWN, location: nil) if path.nil?

        path = path.to_s
        return Site.new(origin: UNKNOWN, location: path) unless File.absolute_path?(path)

        absolute = File.expand_path(path)
        application_site(absolute, root) || gem_site(absolute) || stdlib_site(absolute) ||
          Site.new(origin: UNKNOWN, location: "#{EXTERNAL}/#{File.basename(absolute)}")
      end

      # @param path [String, nil]
      # @param root [String, Pathname, nil]
      # @return [String] one of {APP}, {FRAMEWORK}, {GEM}, {UNKNOWN}
      def origin(path, root: application_root)
        site(path, root: root).origin
      end

      # @param path [String, nil]
      # @param root [String, Pathname, nil]
      # @return [String, nil] the stable label, nil without a path
      def location(path, root: application_root)
        site(path, root: root).location
      end

      # Whether a gem name is one of the Rails gems.
      #
      # @param name [String]
      # @return [Boolean]
      def framework_gem?(name)
        RAILS_GEMS.include?(name)
      end

      # The gem name of a gem directory: `activerecord-7.1.6` => `activerecord`.
      #
      # @param dir [String]
      # @return [String]
      def gem_name(dir)
        version_at = dir.index(/-\d/)
        return dir[0...version_at] if version_at

        sha_at = dir.rindex('-')
        return dir[0...sha_at] if sha_at && GIT_SHA.match?(dir[(sha_at + 1)..])

        dir
      end

      # The gem directory and the path below it, cut at the last +marker+.
      #
      # @param absolute [String]
      # @param marker [String] {GIT_GEM} or {INSTALLED_GEM}
      # @return [Array(String, String), nil] dir and rest, or nil when the
      #   marker is absent or either side is empty
      def gem_parts(absolute, marker)
        at = absolute.rindex(marker)
        return nil unless at

        dir, rest = absolute[(at + marker.length)..].split('/', 2)
        return nil if dir.nil? || dir.empty? || rest.nil? || rest.empty?

        [dir, rest]
      end

      # Directories gems are installed into, as absolute paths with a trailing
      # separator. A bundle configured under the application root (`.bundle`,
      # `tmp/bundle`) puts framework source below the root prefix.
      #
      # @return [Array<String>]
      def gem_install_roots
        roots = Gem.path.dup
        roots << Bundler.bundle_path.to_s if defined?(Bundler) && Bundler.respond_to?(:bundle_path)
        roots.uniq.map { |root| File.expand_path(root).delete_suffix(File::SEPARATOR) + File::SEPARATOR }
      rescue StandardError
        []
      end

      # @return [String, nil] +Rails.root+ when Rails is loaded
      def application_root
        return nil unless defined?(Rails) && Rails.respond_to?(:root)

        Rails.root&.to_s
      rescue StandardError
        nil
      end

      # @param absolute [String]
      # @param root [String, Pathname, nil]
      # @return [Site, nil]
      def application_site(absolute, root)
        return nil if root.nil? || root.to_s.empty?

        prefix = File.expand_path(root.to_s).delete_suffix(File::SEPARATOR) + File::SEPARATOR
        return nil unless absolute.start_with?(prefix)

        relative = absolute.delete_prefix(prefix)
        return nil if relative.split(File::SEPARATOR).any? { |part| FOREIGN_SEGMENTS.include?(part) }
        if gem_install_roots.any? { |dir| dir.start_with?(prefix) && dir != prefix && absolute.start_with?(dir) }
          return nil
        end

        Site.new(origin: APP, location: relative)
      end

      # @param absolute [String]
      # @return [Site, nil]
      def gem_site(absolute)
        dir, rest = gem_parts(absolute, GIT_GEM) || gem_parts(absolute, INSTALLED_GEM)
        return Site.new(origin: gem_origin(gem_name(dir)), location: "#{dir}/#{rest}") if dir

        loaded_gem_site(absolute)
      end

      # A gem loaded from somewhere the directory patterns do not name: a
      # `path:` gem, or a gem home with another layout.
      #
      # @param absolute [String]
      # @return [Site, nil]
      def loaded_gem_site(absolute)
        return nil unless defined?(Gem) && Gem.respond_to?(:loaded_specs)

        holders = Gem.loaded_specs.values.filter_map do |candidate|
          dir = candidate.full_gem_path.to_s
          next if dir.empty?

          dir = File.expand_path(dir).delete_suffix(File::SEPARATOR) + File::SEPARATOR
          [candidate, dir] if absolute.start_with?(dir)
        end
        spec, prefix = holders.max_by { |_, dir| dir.length }
        return nil unless spec

        Site.new(origin: gem_origin(spec.name), location: "#{spec.full_name}/#{absolute.delete_prefix(prefix)}")
      rescue StandardError
        nil
      end

      # @param absolute [String]
      # @return [Site, nil]
      def stdlib_site(absolute)
        dir = RbConfig::CONFIG['rubylibdir'].to_s
        return nil if dir.empty?

        prefix = File.expand_path(dir).delete_suffix(File::SEPARATOR) + File::SEPARATOR
        return nil unless absolute.start_with?(prefix)

        Site.new(origin: GEM, location: "#{RUBY}/#{absolute.delete_prefix(prefix)}")
      end

      # @param name [String] a gem name
      # @return [String] {FRAMEWORK} or {GEM}
      def gem_origin(name)
        framework_gem?(name) ? FRAMEWORK : GEM
      end

      private_class_method :application_site, :gem_site, :loaded_gem_site, :stdlib_site, :gem_origin
    end
  end
end
