# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'atomic_file'
require_relative 'path_dispatcher'
require_relative 'extractors/poro_extractor'

module Woods
  # Ruby files under the configured sweep roots that produced no unit, each
  # with the reason it was skipped.
  #
  # Reasons:
  # * +rejected_by:<key>+ — a file rule owns the path, or a class-discovered
  #   extractor owns the class, and that extractor emitted nothing for it
  # * +parse_error+ — Prism could not parse the file
  # * +no_declaration+ — no class, module, or Struct/Data assignment
  # * +namespace_only+ — modules with no methods, constants, classes, or hook blocks
  # * +not_owned+ — a declaration whose ownership could not be proven here
  #   (unloaded, reopened from another file, or methods defined elsewhere)
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
      globs = [Extractors::PoroExtractor::MODELS_GLOB, *Woods.configuration&.unclaimed_ruby_paths]
      globs.flat_map { |glob| Dir.glob(glob, File::FNM_EXTGLOB, base: @root) }.uniq.sort.select do |relative|
        relative.end_with?('.rb') && PathDispatcher::UNSWEPT_PREFIXES.none? { |prefix| relative.start_with?(prefix) } &&
          File.file?(File.join(@root, relative))
      end
    end

    def reason_for(relative)
      key = PathDispatcher.claiming_key_for(relative)
      return "rejected_by:#{key}" if key

      @poro.skip_reason(File.join(@root, relative))
    end

    def relativize(path)
      path.start_with?('/') ? path.delete_prefix("#{@root}/") : path
    end
  end
end
