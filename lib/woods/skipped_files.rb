# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'atomic_file'
require_relative 'path_dispatcher'
require_relative 'extractors/poro_extractor'
require_relative 'extractors/graphql_operation_extractor'
require_relative 'extractors/lib_extractor'
require_relative 'graphql_document_paths'

module Woods
  # Ruby files under the configured sweep roots, and GraphQL operation
  # documents under the configured document roots, that produced no unit,
  # each with the reason it was skipped. Generator templates under `lib/` are
  # listed too: they carry a Ruby extension and are never extracted.
  #
  # Reasons for Ruby files:
  # * +template+ — a generator template, ERB that is not parseable Ruby
  # * +rejected_by:<key>+ — a file rule owns the path, or a class-discovered
  #   extractor owns the class, and that extractor emitted nothing for it
  # * +parse_error+ — Prism could not parse the file
  # * +no_declaration+ — no class, module, or Struct/Data assignment
  # * +namespace_only+ — modules with no methods, constants, classes, or hook blocks
  # * +not_owned+ — a declaration whose ownership could not be proven here
  #   (unloaded, reopened from another file, or methods defined elsewhere)
  #
  # Reasons for GraphQL documents (`config.graphql_document_paths`):
  # * +graphql_unavailable+ — the graphql gem is not loaded, so no document is read
  # * +schema_definitions+ — the file holds type definitions (an SDL dump), not operations
  # * +parse_error+ — graphql-ruby could not parse the file
  #
  # The report is a pure function of the tree and the published unit paths,
  # so full and incremental runs produce the same bytes.
  class SkippedFiles
    FILENAME = 'skipped_files.json'

    # @param root [String] application root
    # @param poro [Extractors::PoroExtractor] classifier for unowned files
    def initialize(root:, poro: Extractors::PoroExtractor.new)
      @root = root.to_s
      @poro = poro
    end

    # @param unit_paths [Enumerable<String, nil>] every unit's file_path, absolute or root-relative
    # @return [Hash] +total+, +counts+ by reason, and +files+ sorted by path
    def build(unit_paths)
      covered = unit_paths.compact.to_set { |path| relativize(path.to_s) }
      files = candidates.reject { |relative| covered.include?(relative) }.map do |relative|
        { 'path' => relative, 'reason' => reason_for(relative) }
      end
      counts = files.map { |entry| entry['reason'] }.tally.sort.to_h
      { 'total' => files.size, 'counts' => counts, 'files' => files }
    end

    # @param payload_dir [Pathname] generation payload directory
    # @param report [Hash] result of {#build}
    # @param durable [Boolean] fsync the file before returning
    # @return [void]
    def self.write(payload_dir, report, durable:)
      AtomicFile.write(Pathname(payload_dir).join(FILENAME), JSON.generate(report), durable: durable)
    end

    # @param payload_dir [Pathname] generation payload directory
    # @return [Hash, nil] the published report, or nil when the generation has none
    def self.read(payload_dir)
      path = Pathname(payload_dir).join(FILENAME)
      path.file? ? JSON.parse(AtomicFile.read(path)) : nil
    end

    private

    def candidates
      (ruby_candidates + GraphQLDocumentPaths.under(@root)).sort
    end

    def ruby_candidates
      globs = [Extractors::PoroExtractor::MODELS_GLOB, *Woods.configuration&.unclaimed_ruby_paths,
               Extractors::LibExtractor::TEMPLATE_GLOB]
      globs.flat_map { |glob| Dir.glob(glob, File::FNM_EXTGLOB, base: @root) }.uniq.select do |relative|
        relative.end_with?('.rb') && PathDispatcher::UNSWEPT_PREFIXES.none? { |prefix| relative.start_with?(prefix) } &&
          File.file?(File.join(@root, relative))
      end
    end

    # The file's own shape decides first, so `module Admin; end` under an
    # owned directory reads namespace_only, not rejected_by its owner.
    def reason_for(relative)
      return 'template' if Extractors::LibExtractor.generator_template?(relative)

      path = File.join(@root, relative)
      return Extractors::GraphQLOperationExtractor.document_skip_reason(path) if GraphQLDocumentPaths.match?(relative)

      static = @poro.static_skip_reason(path)
      return static if static

      key = PathDispatcher.claiming_key_for(relative)
      key ? "rejected_by:#{key}" : @poro.skip_reason(path)
    end

    def relativize(path)
      path.start_with?('/') ? path.delete_prefix("#{@root}/") : path
    end
  end
end
