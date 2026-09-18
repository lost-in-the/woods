# frozen_string_literal: true

require 'time'
require 'woods/source_inputs/scanner'
require 'woods/source_inputs/manifest'

module Woods
  module SourceInputs
    # Bounded, byte-verifying source evidence. No stat-only result is called
    # current: the same-size/same-mtime case is deliberately read and hashed.
    class Verifier
      DEFAULT_SECONDS = 0.25
      SUMMARY_LIMIT = 30

      # rubocop:disable Metrics/ParameterLists -- caller chooses identity, served generation and bounded scan
      def initialize(manifest:, output_dir:, root: nil, generation: nil, max_seconds: DEFAULT_SECONDS, **limits)
        @manifest = manifest.is_a?(Manifest) ? manifest : Manifest.new(manifest)
        @output_dir = output_dir
        @root = root || @manifest.data.fetch('root')
        @generation = generation
        @limits = limits.merge(max_seconds: max_seconds)
      end

      # rubocop:enable Metrics/ParameterLists

      def call # rubocop:disable Metrics/AbcSize -- cheap refusal checks precede the only source scan
        return unknown('generation_mismatch') if @generation && @generation != @manifest.data['generation']
        return unknown('source_root_unavailable') unless File.directory?(@root)

        key = PrivateKey.new(output_dir: @output_dir)
        return unknown('identity_key_mismatch') unless key.identifier == @manifest.data.fetch('key_id')

        scopes = Scopes.new(extra_roots: @manifest.data.fetch('extra_roots'))
        return unknown('input_rules_changed') unless scopes.fingerprint == @manifest.data.fetch('rules')

        current = Scanner.new(root: @root, output_dir: @output_dir, key: key, scopes: scopes, **@limits).call
        compare(current)
      rescue PrivateKey::Unavailable => e
        unknown(e.message)
      rescue SystemCallError, IOError
        unknown('source_root_unavailable')
      end

      private

      def compare(current)
        previous = @manifest.expanded
        changes = { 'added' => [], 'changed' => [], 'removed' => [] }
        previous.each { |scope, paths| compare_scope(scope, paths, changes, current) }
        add_new_scopes(previous, changes, current) if complete?(current)
        reasons = coverage_reasons(current)
        summarized(changes, reasons, current)
      end

      def complete?(current)
        @manifest.data['complete'] && current['complete']
      end

      def compare_scope(scope, paths, changes, current)
        paths.each do |path, identity|
          now = current.fetch('files')[path]
          changes['changed'] << path if now && now != identity
          changes['removed'] << path if now.nil? && current['complete']
        end
        return unless complete?(current)

        changes['added'].concat(current.fetch('scope_paths').fetch(scope, []) - paths.keys)
      end

      def add_new_scopes(previous, changes, current)
        new_scopes = current.fetch('scope_paths').keys - previous.keys
        new_scopes.each { |scope| changes['added'].concat(current.fetch('scope_paths').fetch(scope)) }
      end

      def coverage_reasons(current)
        reasons = (@manifest.data.fetch('errors') + current.fetch('errors')).map { |error| error['reason'] }.compact
        reasons << 'incomplete_capture' unless @manifest.data['complete']
        reasons << 'incomplete_verification' unless current['complete']
        reasons << 'unverified_boot_boundary' unless @manifest.data['boot_verified']
        reasons << 'unverified_consumption_scopes' unless @manifest.data.fetch('unverified_scopes').empty?
        reasons.uniq
      end

      def summarized(changes, reasons, current)
        changes.transform_values! { |paths| paths.uniq.sort }
        counts = changes.transform_values(&:size)
        { 'state' => state_for(counts, reasons), 'mode' => 'content', 'generation' => @manifest.data['generation'],
          'checked_at' => Time.now.utc.iso8601, 'reasons' => reasons,
          'complete' => current['complete'] && @manifest.data['complete'],
          'counts' => counts, 'truncated' => counts.values.any? { |count| count > SUMMARY_LIMIT },
          'changes' => changes.transform_values { |paths| paths.first(SUMMARY_LIMIT) },
          'metrics' => current.fetch('metrics') }
      end

      def state_for(counts, reasons)
        return 'drifted' if counts.values.any?(&:positive?)

        reasons.empty? ? 'current' : 'unknown'
      end

      def unknown(reason)
        { 'state' => 'unknown', 'mode' => 'content', 'generation' => @manifest.data['generation'],
          'checked_at' => Time.now.utc.iso8601, 'reasons' => [reason], 'complete' => false }
      end
    end
  end
end
