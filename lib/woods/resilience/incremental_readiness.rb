# frozen_string_literal: true

require 'json'
require 'pathname'
require 'rubygems/version'
require_relative '../atomic_file'
require_relative '../generation'
require_relative '../source_references/cache'
require_relative '../source_references/registry'
require_relative '../source_references/runtime_lookup'

module Woods
  module Resilience
    # Whether the published index can take an incremental run.
    #
    # This is a different question from index validity. {IndexValidator}
    # answers "can a reader use this index", and older indexes must keep
    # passing it. A partial writer needs more: a modern layout, a 2.x writer and
    # a source reference cache it can replay. This reports that without
    # booting Rails, so validation and `woods_status` can warn before
    # `woods:incremental` refuses.
    #
    # It covers the baseline on disk. Refusals that depend on the live
    # configuration or current source bytes (a changed extraction fingerprint,
    # a changed `source_reference_callers`, an unverifiable source file) are
    # still decided by the run itself.
    class IncrementalReadiness
      # @!attribute [r] ready?
      #   @return [Boolean]
      # @!attribute [r] reason
      #   @return [String, nil] why a full extraction is needed
      Result = Struct.new(:ready?, :reason, keyword_init: true) do
        # @return [String] `ready`, or `needs full extraction (<reason>)`
        def to_s
          ready? ? 'ready' : "needs full extraction (#{reason})"
        end
      end

      # The baseline manifest and the problem that stops a partial writer.
      WriterCheck = Struct.new(:manifest, :problem, keyword_init: true)

      # Writer majors below this cannot be migrated by a partial writer.
      MINIMUM_WRITER_MAJOR = 2

      # Check the layout and the manifest writer of the published generation.
      # This is the one definition shared with the extractor's refusal.
      #
      # @param generation [Woods::Generation]
      # @return [WriterCheck] a nil manifest means nothing is published to check
      def self.check_writer(generation)
        directory = generation.payload_dir
        manifest_path = directory.join('manifest.json')
        return WriterCheck.new unless manifest_path.file?

        return WriterCheck.new(problem: "a legacy flat index under #{generation.root}") if directory == generation.root

        manifest = JSON.parse(AtomicFile.read(manifest_path))
        writer = manifest.fetch('woods_version', nil)
        supported = writer.nil? || Gem::Version.new(writer).segments.first >= MINIMUM_WRITER_MAJOR
        return WriterCheck.new(manifest: manifest) if supported

        WriterCheck.new(problem: "an index written by Woods #{writer}")
      rescue JSON::ParserError, ArgumentError, TypeError, NoMethodError => e
        WriterCheck.new(problem: "the baseline manifest writer cannot be verified (#{e.class})")
      end

      # @param index_dir [String, Pathname] the index output directory
      def initialize(index_dir:)
        @generation = Generation.new(output_dir: index_dir)
      end

      # @return [Result]
      def call
        check = self.class.check_writer(@generation)
        return not_ready("no published index under #{@generation.root}") unless check.manifest || check.problem
        return not_ready(check.problem) if check.problem

        problem = cache_problem(@generation.payload_dir)
        problem ? not_ready(problem) : Result.new(ready?: true)
      rescue SystemCallError, IOError => e
        not_ready("the published index cannot be read (#{e.class})")
      end

      private

      def not_ready(reason)
        Result.new(ready?: false, reason: reason)
      end

      def cache_problem(payload)
        cache = SourceReferences::Cache.read(payload.join(SourceReferences::Cache::FILE_NAME))
        return if cache
        return unless reference_nodes?(payload)

        'the source reference cache is missing'
      rescue SourceReferences::Cache::Invalid => e
        "the source reference cache is unusable (#{e.message})"
      end

      # Mirrors the extractor's test for a unit that must be in the cache, read
      # from the serialized graph so no Rails boot is needed.
      def reference_nodes?(payload)
        graph = JSON.parse(AtomicFile.read(payload.join('dependency_graph.json')))
        graph.fetch('nodes', {}).any? { |identifier, node| reference_node?(identifier, node) }
      rescue JSON::ParserError, SystemCallError
        true
      end

      def reference_node?(identifier, node)
        return false unless node.is_a?(Hash) && SourceReferences::Registry::TYPES.map(&:to_s).include?(node['type'])

        SourceReferences::RuntimeLookup::CONSTANT.match?(identifier) && source_path?(node['file_path'])
      end

      def source_path?(path)
        path.is_a?(String) && path.match?(%r{\A(?:app|lib)/.*\.rb\z}) &&
          path.split('/').none? { |part| %w[vendor node_modules assets].include?(part) }
      end
    end
  end
end
