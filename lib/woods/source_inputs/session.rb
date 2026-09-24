# frozen_string_literal: true

require_relative '../source_contributors'

require 'set'
require 'woods/source_inputs/scanner'
require 'woods/source_inputs/manifest'
require 'woods/source_inputs/handoff'
require 'woods/source_inputs/consumer_errors'
require 'woods/source_inputs/stable_reader'

module Woods
  module SourceInputs
    # Records successful consumers, never merely paths found by a final scan.
    # An incremental run starts from the preceding generation's scope ledger.
    class Session # rubocop:disable Metrics/ClassLength -- per-run consumer ledger and publication coverage
      MAX_ERRORS = 30

      def initialize(root:, output_dir:, baseline_path:, operation:)
        @root = SourcePathEncoding.expand(root)
        @output = SourcePathEncoding.expand(output_dir)
        @operation = operation.to_s
        @errors = []
        @unverified = []
        @baseline = read_baseline(baseline_path)
        @rules = Scopes.new(extra_roots: declared_roots)
        @key = PrivateKey.new(output_dir: @output, create: true)
        handoff = Handoff.read(root: @root, output_dir: @output, operation: @operation, rules: @rules.fingerprint,
                               key_id: @key.identifier)
        @snapshot = handoff || scan
        @verified_boot = !handoff.nil?
        @identities = initial_identities
      rescue PrivateKey::Unavailable => e
        @snapshot = unavailable_snapshot(e.message)
        @identities = {}
        @verified_boot = false
      end

      # Read original captured bytes, without certifying runtime consumption.
      #
      # @param path [String] root-relative or absolute application source path
      # @param limits [Hash] StableReader byte/time budget overrides
      # @return [Hash] original source bytes, relative path and captured HMAC
      # @raise [StableReader::Error] when source cannot be read as captured
      def read_source(path, **limits)
        raise StableReader::Error, 'source_identity_unavailable' unless @key

        identity = source_identity(path)
        raise StableReader::Error, 'uncaptured_source_path' unless identity

        StableReader.new(root: @root, key: @key).read(path, identity: identity, **limits)
      end

      # @param path [String] root-relative or absolute application source path
      # @return [String, nil] captured private HMAC, never a public raw content hash
      def source_identity(path)
        @snapshot.fetch('files')[relative_path(path)]&.dup&.freeze
      end

      # A fresh read cannot establish which bytes produced retained runtime facts.
      # This checks only explicit unit consumption against this session's capture.
      #
      # @param key [String, Symbol] extractor ledger key
      # @param path [String] root-relative or absolute application source path
      # @return [Boolean] whether that unit consumer acknowledged captured bytes
      def consumed_source?(key, path)
        identity = source_identity(path)
        !identity.nil? && @identities.fetch("unit:#{key}", {})[relative_path(path)] == identity
      end

      def consume_file(key, path)
        consume_path("file:#{key}", path)
        consume_path("unit:#{key}", path) if @identities.fetch("unit:#{key}", {}).key?(relative_path(path))
      end

      def consume_unit(key, path)
        consume_path("unit:#{key}", path)
      end

      def consume_deleted(path) # rubocop:disable Metrics/CyclomaticComplexity -- deletion preserves boot provenance
        relative = relative_path(path)
        return if relative.nil? || @snapshot.fetch('files').key?(relative)

        @rules.for_path(relative).each { |scope| @identities[scope]&.delete(relative) unless scope == 'boot' }
        @identities.each { |scope, paths| paths.delete(relative) if scope.start_with?('unit:') }
      end

      def consume_extractor(key, units)
        ["file:#{key}", "whole:#{key}"].each { |scope| replace_scope(scope) }
        @identities["unit:#{key}"] = {}
        Array(units).each { |unit| SourceContributors.paths(unit).each { |path| consume_unit(key, path) } }
      end

      def unverified(scope)
        @unverified << scope.to_s
      end

      def full_units(results, consumers: {})
        results.each do |key, units|
          if ConsumerErrors.failed?(consumers[key])
            unverified("extractor:#{key}")
            # ModelExtractor's per-model rescue returns nil. Every returned
            # model crossed that boundary successfully, even if a sibling did
            # not. Other extractors may return partial results after a rescue.
            if key == :models
              Array(units).each do |unit|
                SourceContributors.paths(unit).each do |path|
                  consume_unit(key, path)
                end
              end
            end
          else
            consume_extractor(key, units)
          end
        end
      end

      def finish(generation:, eager_load_complete:)
        verify_stability
        verify_loaded_source_coverage
        if @operation != 'full'
          preserve_baseline_coverage
          # Fresh discovery is not proof that every retained runtime fact was
          # serialized again. Keep this limitation explicit even when bytes match.
          @unverified << 'runtime_consumption' if runtime_inputs_changed?
          replace_scope('runtime') if @verified_boot && eager_load_complete
        end
        @unverified << 'incomplete_eager_load' unless eager_load_complete
        Manifest.build(snapshot: @snapshot, scopes: @identities, boot_verified: verified_coverage?,
                       generation: generation, errors: @errors, unverified_scopes: @unverified,
                       comparison_complete: comparison_complete?)
      end

      private

      def record_error(error)
        # Bound path samples independently so noisy unit diagnostics cannot
        # hide a later instability reason or its watcher catch-up paths.
        count = @errors.count { |existing| existing['reason'] == error['reason'] }
        @errors << error if count < MAX_ERRORS && !@errors.include?(error)
      end

      def comparison_complete?
        @operation == 'full' || !!(compatible_baseline? && @baseline.comparison_complete?)
      end

      def declared_roots
        roots = Handoff.extra_roots
        roots.empty? && @baseline ? @baseline.data.fetch('extra_roots') : roots
      end

      def read_baseline(path)
        return nil if path.nil? || !File.file?(path)

        File.open(path, File::RDONLY | File::NONBLOCK) do |file|
          raise Manifest::Invalid, 'source_manifest_too_large' if file.stat.size > Manifest::MAX_BYTES

          Manifest.parse(file.read(Manifest::MAX_BYTES + 1))
        end
      rescue Manifest::Invalid, SystemCallError, IOError
        record_error('reason' => 'invalid_source_baseline') unless @operation == 'full'
        nil
      end

      def initial_identities
        return snapshot_identities if @operation == 'full'
        return @baseline.expanded if compatible_baseline?

        record_error('reason' => 'missing_or_incompatible_source_baseline')
        {}
      end

      def compatible_baseline?
        @baseline && @baseline.data['key_id'] == @snapshot['key_id'] &&
          @baseline.data['rules'] == @snapshot['rules'] && @baseline.data['root'] == @root
      end

      def snapshot_identities
        @snapshot.fetch('scope_paths').transform_values do |paths|
          paths.to_h { |path| [path, @snapshot.fetch('files').fetch(path)] }
        end
      end

      def consume_path(scope, path)
        relative = relative_path(path)
        return if relative.nil?

        identity = @snapshot.fetch('files')[relative]
        if identity
          (@identities[scope] ||= {})[relative] = identity
        elsif File.exist?(File.join(@root, relative))
          record_error('reason' => 'uncaptured_source_path', 'path' => relative)
        else
          @identities[scope]&.delete(relative)
        end
      end

      def relative_path(path)
        return nil if path.nil? || path.to_s.empty?

        decoded = SourcePathEncoding.utf8(path)
        unless decoded
          record_error('reason' => 'undecodable_source_path', 'path' => SourcePathEncoding.diagnostic(path))
          return nil
        end

        application_source_path(File.expand_path(decoded, @root))
      end

      def application_source_path(absolute)
        # Installed gem/framework source is outside application-source coverage.
        return nil unless absolute.start_with?("#{@root}/")

        relative = absolute.delete_prefix("#{@root}/")
        return relative if @rules.extra_roots.any? { |root| relative.start_with?("#{root}/") }
        return nil if installed_gem_roots.any? { |root| absolute.start_with?("#{root}/") }

        relative
      end

      # A vendor-shaped path alone is not ownership evidence. Local path gems
      # have their gemspec in the checkout, not in an installation's metadata.
      def installed_gem_roots
        @installed_gem_roots ||= Gem.loaded_specs.values.filter_map { |spec| installed_gem_root(spec) }
      end

      def installed_gem_root(spec)
        return unless spec.loaded_from && File.file?(spec.loaded_from)

        base = File.expand_path(spec.base_dir)
        path = File.expand_path(spec.full_gem_path)
        return unless File.expand_path(spec.loaded_from).start_with?("#{base}/specifications/") &&
                      path.start_with?("#{base}/gems/") && File.directory?(path)

        path
      end

      def replace_scope(scope)
        paths = @snapshot.fetch('scope_paths').fetch(scope, [])
        @identities[scope] = paths.to_h { |path| [path, @snapshot.fetch('files').fetch(path)] }
      end

      def runtime_inputs_changed?
        return true unless compatible_baseline?

        before = @baseline.expanded.fetch('runtime', {})
        now = snapshot_identities.fetch('runtime', {})
        before != now
      end

      def verified_coverage?
        return @verified_boot if @operation == 'full'

        !!(@verified_boot && compatible_baseline? && @baseline.data['boot_verified'])
      end

      def preserve_baseline_coverage
        return unless @baseline

        @baseline.data.fetch('errors').each { |error| record_error(error) }
        @unverified.concat(@baseline.data.fetch('unverified_scopes'))
        record_error('reason' => 'incomplete_source_baseline') unless @baseline.data['complete']
      end

      def verify_stability
        return unless @key

        after = scan
        after.fetch('errors').each { |error| record_error(error) }
        changed_paths(after).first(MAX_ERRORS).each do |path|
          record_error('reason' => 'source_changed_during_extraction', 'path' => path)
        end
      end

      def changed_paths(after)
        before_files = @snapshot.fetch('files')
        after_files = after.fetch('files')
        changed = (before_files.keys & after_files.keys).reject { |path| before_files[path] == after_files[path] }
        changed.concat(after_files.keys - before_files.keys) if @snapshot['complete']
        changed.concat(before_files.keys - after_files.keys) if after['complete']
        changed
      end

      # A custom loader can consume Ruby outside the standard dispatch roots.
      # Loaded-feature evidence can disprove coverage, never expand a capture
      # after boot and retroactively claim those bytes were consumed.
      def verify_loaded_source_coverage
        paths = $LOADED_FEATURES.filter_map do |path|
          # Ruby 3 also lists built-in pseudo features, such as thread.rb.
          next unless path.start_with?('/') || File.file?(File.expand_path(path, @root))

          relative_path(path)
        end.uniq
        missing = paths - @snapshot.fetch('files').keys
        missing.first(30).each do |path|
          record_error('reason' => 'loaded_source_outside_coverage', 'path' => path)
        end
      end

      def scan
        Scanner.new(root: @root, output_dir: @output, key: @key, scopes: @rules).call
      end

      def unavailable_snapshot(reason)
        { 'root' => @root, 'key_id' => '0' * 64, 'rules' => @rules.fingerprint,
          'extra_roots' => @rules.extra_roots, 'files' => {}, 'scope_paths' => {}, 'complete' => false,
          'errors' => [{ 'reason' => reason }], 'metrics' => {} }
      end
    end
  end
end
