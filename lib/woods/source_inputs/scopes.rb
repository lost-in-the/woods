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

      # What the walk skips before any scope is matched, as status reports
      # it. Declared roots override the generic directory and hidden-entry
      # exclusions; the index output is always skipped.
      #
      # @param output_dir [String]
      # @return [Hash]
      def self.exclusions(output_dir:)
        kept = Watch::TreeScan::NOT_IGNORED_DOTFILES +
               Watch::TreeScan::NOT_IGNORED_DOTFILE_PREFIXES.map { |prefix| "#{prefix}*" } +
               Watch::TreeScan::VISIBLE_DOT_DIRECTORIES
        { 'directories' => Watch::Watcher::DEFAULT_IGNORED_DIRECTORIES, 'hidden_entries' => true,
          'hidden_kept' => kept, 'index_output' => SourcePathEncoding.expand(output_dir) }
      end

      def initialize(extra_roots: [])
        require 'woods/extractor' unless defined?(Woods::Extractor::EXTRACTORS)
        @extra_roots = Array(extra_roots).map { |path| validate_root(path) }.uniq.sort
        @file_rules = PathDispatcher.file_rules
        @whole_rules = PathDispatcher.whole_app_rules
        @policy = ReloadPolicy.new
        @rule_scopes = self.class.shared_rule_scopes(matching_key)
      end

      # The rule scopes matched so far in this process for one matching key:
      # the rule set, the extra roots and the configuration the matchers read
      # ({#matching_key}). A resident process (the watch daemon, a long
      # session) classifies the same tree on every run, and matching every
      # rule against every path was a third of a run's source capture; a key
      # that differs from the last one starts a new table.
      #
      # @param key [Array]
      # @return [Hash{String => Array<String>}]
      def self.shared_rule_scopes(key)
        (@shared_rule_scopes_lock ||= Mutex.new).synchronize do
          @shared_rule_scopes = [key, {}] unless @shared_rule_scopes&.first == key
          @shared_rule_scopes.last
        end
      end

      # Everything the dispatch rules' matching of a path depends on, so a
      # table keyed by it is valid for every path it holds.
      #
      # @return [Array]
      def matching_key
        configuration = Woods.configuration
        [fingerprint, configuration&.event_paths, configuration&.unclaimed_ruby_paths].freeze
      end

      def for_path(path)
        scopes = []
        action = @policy.classify(path)
        scopes << 'boot' if boot_path?(path, action)
        scopes << 'runtime' if runtime_path?(path, action)
        scopes.concat(rule_scopes(path))
        scopes << 'declared' if @extra_roots.any? { |dir| path.start_with?("#{dir}/") }
        scopes.uniq.sort
      end

      # The dispatch rules' scopes depend only on the path and the rule set,
      # which is fixed for the life of these scopes, so each path is matched
      # once: a run classifies its whole tree twice, at capture and at the
      # publication recheck, and matching is the larger part of classifying.
      #
      # @param path [String]
      # @return [Array<String>] frozen
      def rule_scopes(path)
        @rule_scopes[path] ||= begin
          scopes = @file_rules.filter_map { |rule| "file:#{rule.extractor_key}" if rule.matches?(path) }
          @whole_rules.each { |rule| scopes << "whole:#{rule.extractor_key}" if rule.matches?(path) }
          scopes.freeze
        end
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
                Watch::TreeScan::NOT_IGNORED_DOTFILE_PREFIXES, 'bounded_logical_directory_links_v2',
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
