# frozen_string_literal: true

require 'yaml'
require 'pathname'

module Woods
  module Extractors
    # PackageExtractor reads Packwerk / pks package boundaries (#280).
    #
    # One unit per `package.yml`, identified the way Packwerk names packages:
    # the package directory relative to Rails.root, with `.` for the root
    # package. Declared dependencies become `:package_dependency` edges, so
    # the graph can tell a declared cross-package call from an undeclared
    # one ({Woods::GraphAnalyzer#undeclared_package_edges}). Enforcement stays
    # with `packwerk check` / `pks check`; Woods only makes the boundary
    # visible before an agent writes the call.
    #
    # Pure file read, no Rails boot needed. Registered as a whole-app
    # extractor: a package root decides which package every other unit
    # belongs to, so any `package.yml` change re-runs it wholesale.
    #
    # @example
    #   extractor = PackageExtractor.new
    #   extractor.extract_all.map(&:identifier)        # => [".", "packs/billing"]
    #   extractor.package_for("packs/billing/app/x.rb") # => "packs/billing"
    #
    class PackageExtractor
      PACKAGE_FILE = 'package.yml'
      PACKWERK_CONFIG = 'packwerk.yml'
      ROOT_PACKAGE = '.'

      # Packwerk's own defaults when packwerk.yml is absent or silent.
      DEFAULT_PACKAGE_PATHS = ['**/'].freeze
      DEFAULT_EXCLUDE = ['{bin,node_modules,script,tmp,vendor}/**/*'].freeze

      def initialize
        @rails_root = Pathname.new(Rails.root.to_s)
        @packwerk = load_packwerk_config
      end

      # @return [Array<ExtractedUnit>] one unit per package
      def extract_all
        package_files.filter_map { |path| extract_package_file(path) }
      end

      # Extract one package.yml into a unit.
      #
      # @param file_path [String] absolute path to a package.yml
      # @return [ExtractedUnit, nil] nil when the file is not a YAML mapping
      def extract_package_file(file_path)
        source = File.read(file_path)
        data = YAML.safe_load(source, permitted_classes: [Symbol], aliases: true) || {}
        raise ArgumentError, 'package.yml is not a mapping' unless data.is_a?(Hash)

        name = package_name(file_path)
        dependencies = Array(data['dependencies']).map(&:to_s).uniq.sort

        unit = ExtractedUnit.new(type: :package, identifier: name, file_path: file_path)
        unit.source_code = source
        unit.metadata = {
          name: name,
          dependencies: dependencies,
          enforce_dependencies: normalize_enforcement(data['enforce_dependencies']),
          enforce_privacy: normalize_enforcement(data['enforce_privacy']),
          layer: data['layer'],
          public_path: data['public_path'] || 'app/public',
          owner: data.dig('metadata', 'owner') || data['owner']
        }
        unit.dependencies = dependencies.map { |dep| { type: :package, target: dep, via: :package_dependency } }
        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract package from #{file_path}: #{e.message}")
        nil
      end

      # Package names, longest path first so a nested package wins over its
      # parent, with the root package last. Memoized per instance: an
      # instance lives for one extraction run.
      #
      # @return [Array<String>]
      def package_roots
        @package_roots ||= package_files.map { |path| package_name(path) }
                                        .sort_by { |name| [name == ROOT_PACKAGE ? 1 : 0, -name.length, name] }
      end

      # The package a path belongs to.
      #
      # @param path [String, Pathname] absolute or Rails.root-relative
      # @return [String, nil] nil outside Rails.root or when no package claims it
      def package_for(path)
        relative = relativize(path)
        return nil if relative.nil?

        package_roots.find { |root| root == ROOT_PACKAGE || relative.start_with?("#{root}/") }
      end

      private

      # Every package.yml the packwerk configuration admits, sorted.
      #
      # @return [Array<String>] absolute paths
      def package_files
        @package_files ||= begin
          patterns = Array(@packwerk['package_paths'] || DEFAULT_PACKAGE_PATHS)
          excludes = Array(@packwerk['exclude'] || DEFAULT_EXCLUDE)
          found = patterns.flat_map do |pattern|
            Dir.glob(@rails_root.join(pattern.to_s, PACKAGE_FILE).to_s)
          end
          found.uniq.reject { |path| excluded?(relativize(path), excludes) }.sort
        end
      end

      def excluded?(relative, excludes)
        excludes.any? { |glob| File.fnmatch?(glob.to_s, relative, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
      end

      # @return [Hash] parsed packwerk.yml, or {} when absent or unreadable
      def load_packwerk_config
        path = @rails_root.join(PACKWERK_CONFIG)
        return {} unless path.file?

        data = YAML.safe_load_file(path, permitted_classes: [Symbol], aliases: true)
        data.is_a?(Hash) ? data : {}
      rescue StandardError => e
        Rails.logger.warn("[Woods] Could not read #{PACKWERK_CONFIG}: #{e.message}")
        {}
      end

      # @param file_path [String] absolute path to a package.yml
      # @return [String] Packwerk package name
      def package_name(file_path)
        dir = File.dirname(relativize(file_path).to_s)
        dir == '.' ? ROOT_PACKAGE : dir
      end

      # @return [String, nil] Rails.root-relative path, nil when outside the root
      def relativize(path)
        string = path.to_s
        return string unless string.start_with?('/')

        prefix = "#{@rails_root}/"
        string.start_with?(prefix) ? string.delete_prefix(prefix) : nil
      end

      # Packwerk accepts true, false, and "strict"; keep the value shape.
      def normalize_enforcement(value)
        return false if value.nil? || value == false
        return true if value == true

        value.to_s
      end
    end
  end
end
