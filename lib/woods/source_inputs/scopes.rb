# frozen_string_literal: true

require 'digest'
require 'json'
require 'woods/input_rules'
require 'woods/watch/watcher'
require 'woods/watch/tree_scan'

module Woods
  module SourceInputs
    # Keep each consumer's provenance separate. A whole-app event scan must not
    # bless retained service units that happen to share the same source file.
    class Scopes
      BOOT_FILES = %w[Rakefile config.ru].freeze

      attr_reader :extra_roots

      def initialize(extra_roots: [])
        require 'woods/extractor' unless defined?(Woods::Extractor::EXTRACTORS)
        @extra_roots = Array(extra_roots).map { |path| validate_root(path) }.uniq.sort
        @file_rules = PathDispatcher.file_rules
        @whole_rules = PathDispatcher.whole_app_rules
        @policy = ReloadPolicy.new
      end

      def for_path(path) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- each independent consumer contributes a scope
        scopes = []
        action = @policy.classify(path)
        scopes << 'boot' if boot_path?(path, action)
        scopes << 'runtime' if runtime_path?(path, action)
        @file_rules.each { |rule| scopes << "file:#{rule.extractor_key}" if rule.matches?(path) }
        @whole_rules.each { |rule| scopes << "whole:#{rule.extractor_key}" if rule.matches?(path) }
        scopes << 'declared' if @extra_roots.any? { |dir| path.start_with?("#{dir}/") }
        scopes.uniq.sort
      end

      def boot_path?(path, action)
        return true if action == :restart || BOOT_FILES.include?(path)
        return false unless action == :ignore

        path.match?(%r{\Aconfig/.+\.rb\z}) || path.match?(%r{\A[^/]+\.gemspec\z})
      end

      def runtime_path?(path, action)
        action == :reload && path.end_with?('.rb') && path.match?(%r{\A(?:app|lib)/})
      end

      def fingerprint
        data = [@file_rules.map(&:to_h), @whole_rules.map(&:to_h),
                PathDispatcher.runtime_rules.map(&:to_h),
                ReloadPolicy.constants(false).sort.to_h { |name| [name, ReloadPolicy.const_get(name)] },
                Watch::Watcher::DEFAULT_IGNORED_DIRECTORIES, Watch::TreeScan::NOT_IGNORED_DOTFILES,
                Watch::TreeScan::NOT_IGNORED_DOTFILE_PREFIXES, 'bounded_no_symlink_dirs_v1',
                'config_ruby_and_root_gemspecs_v1', BOOT_FILES, @extra_roots]
        Digest::SHA256.hexdigest(JSON.generate(data))
      end

      private

      def validate_root(value)
        path = value.to_s.delete_suffix('/')
        if path.empty? || path.start_with?('/') || path.include?("\0") ||
           path.split('/', -1).any? { |part| ['', '.', '..'].include?(part) }
          raise ArgumentError, 'source roots must be relative directories under the application root'
        end

        path
      end
    end
  end
end
